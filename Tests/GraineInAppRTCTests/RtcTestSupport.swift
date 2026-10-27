import Foundation
import Network
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * WHAT THE WEBRTC TESTS STAND ON: a clock the test moves, randomness that
 * repeats, sockets the test answers (in memory, or a real WebSocket server on
 * this machine), a call session the test mints, and a peer that does what the
 * test says. Nothing here reaches a real host.
 */

// MARK: - Time

final class ManualRtcTimer: RtcTimer {
    private let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

/// Runs everything inline; timers fire, in order, as the test moves the clock.
final class ManualRtcClock: RtcClock {
    private(set) var now: Double = 1_000
    private var pending: [(id: Int, due: Double, block: () -> Void)] = []
    private var cancelled = Set<Int>()
    private var seq = 0

    func run(_ block: @escaping () -> Void) {
        block()
    }

    func sync<T>(_ block: () -> T) -> T {
        block()
    }

    @discardableResult
    func after(_ seconds: Double, _ block: @escaping () -> Void) -> RtcTimer {
        seq += 1
        let id = seq
        pending.append((id, now + max(0, seconds), block))
        return ManualRtcTimer { [weak self] in self?.cancelled.insert(id) }
    }

    func advance(_ seconds: Double) {
        let target = now + seconds
        while true {
            let due = pending.enumerated()
                .filter { $0.element.due <= target + 1e-9 && !cancelled.contains($0.element.id) }
                .min { ($0.element.due, $0.element.id) < ($1.element.due, $1.element.id) }
            guard let next = due else { break }
            pending.remove(at: next.offset)
            now = max(now, next.element.due)
            next.element.block()
        }
        now = target
        pending.removeAll { cancelled.contains($0.id) }
    }
}

// MARK: - Randomness that repeats

/// Counts instead of guessing: every token, branch and id is predictable, in JsSIP's alphabets.
final class CountingRandom: SipRandom {
    private var n = 0
    private var branches = 0

    func token(_ count: Int) -> String {
        n += 1
        let base = "t" + String(n, radix: 32)
        if base.count >= count { return String(base.prefix(count)) }
        return base + String(repeating: "0", count: count - base.count)
    }

    func branch() -> String {
        branches += 1
        return "z9hG4bK\(1_000_000 + branches)"
    }

    func initialCSeq() -> Int { 367 }
    func uuid() -> String { "c30c2118-f5c4-4dd6-898c-3d8485be8150" }
    func sessionId() -> String { "0123456789abcdef0123456789abcdef" }
}

// MARK: - Sockets in memory

final class MemorySocket: RtcSocket {
    let url: URL
    let protocols: [String]
    let events: RtcSocketEvents
    private(set) var sent: [String] = []
    private(set) var closedByClient = false

    init(url: URL, protocols: [String], events: RtcSocketEvents) {
        self.url = url
        self.protocols = protocols
        self.events = events
    }

    func send(_ text: String) {
        guard !closedByClient else { return }
        sent.append(text)
        onSend?(text)
    }

    func close() { closedByClient = true }

    /// What the test's server does with each message the client sends.
    var onSend: ((String) -> Void)?

    func open() { events.opened() }
    func deliver(_ text: String) { events.received(text) }
    func serverClose(_ code: Int? = 1000, _ detail: String = "closed") { events.closed(code, detail) }

    var sentMessages: [SipMessage] { sent.compactMap { SipParser.parse($0) } }
}

final class MemorySocketFactory: RtcSocketFactory {
    private(set) var sockets: [MemorySocket] = []
    /// Called for every socket the code opens, before it is returned.
    var onOpen: ((MemorySocket) -> Void)?

    func open(_ url: URL, protocols: [String], events: RtcSocketEvents) -> RtcSocket {
        let socket = MemorySocket(url: url, protocols: protocols, events: events)
        sockets.append(socket)
        onOpen?(socket)
        return socket
    }

    var sip: [MemorySocket] { sockets.filter { $0.protocols == ["sip"] } }
    var control: [MemorySocket] { sockets.filter { $0.protocols.isEmpty } }
}

// MARK: - A scripted SBC, in memory (for the engine)

/**
 * Answers like production's SBC (TRACE.md): every REGISTER and INVITE is
 * challenged with a 401 first; the INVITE gets 100 Trying, then the 401, then
 * (authorised) 100 and 200 with an answer whose Contact is the SBC's TCP
 * address. Each step can be withheld or replaced by the test.
 */
final class ScriptedSbc {
    var registerReply: Int? = 200
    var challenge = true
    var inviteFinal: Int? = 200
    var sendTrying = true
    var answerSdp = TraceSdp.answer
    var received: [SipMessage] = []
    /// Hold the INVITE's final answer until the test releases it (`releaseFinal`), so a test can say how long the dial took.
    var holdFinal = false
    private var heldFinal: (() -> Void)?
    private var nonce = 0
    /// A re-INVITE (an ICE restart) is answered with this: 200 with the answer, another code as a refusal.
    var reinviteFinal = 200
    /// Hold each re-INVITE's answer until the test releases it (`releaseReinvite`).
    var holdReinvite = false
    private var heldReinvite: (() -> Void)?

    func releaseReinvite() {
        let held = heldReinvite
        heldReinvite = nil
        held?()
    }

    func releaseFinal() {
        let held = heldFinal
        heldFinal = nil
        held?()
    }

    func attach(_ socket: MemorySocket) {
        socket.onSend = { [weak self, weak socket] text in
            guard let self = self, let socket = socket, let message = SipParser.parse(text) else { return }
            self.received.append(message)
            self.handle(message, on: socket)
        }
    }

    func handle(_ m: SipMessage, on socket: MemorySocket) {
        guard let method = m.method else { return }
        switch method {
        case "REGISTER":
            if challenge && m.header("Authorization") == nil {
                socket.deliver(Self.reply(m, 401, extra: [Self.wwwAuthenticate(next())]))
            } else if let code = registerReply {
                socket.deliver(Self.reply(m, code, toTag: "reg1", extra: code == 200 ? ["Contact: \(m.headerValues("Contact").first ?? "")", "Expires: \(m.header("Expires") ?? "300")"] : []))
            }
        case "INVITE":
            if m.toTag != nil {
                // A re-INVITE (an ICE restart): answered at once, unless the test holds or refuses it.
                let code = reinviteFinal
                let sdp = answerSdp
                let answer = { [weak socket] in
                    guard let socket = socket else { return }
                    if code == 200 {
                        socket.deliver(Self.reply(m, 200, toTag: m.toTag, extra: ["Contact: <sip:198.51.100.7:5060;transport=tcp>", "Content-Type: application/sdp"], body: sdp))
                    } else {
                        socket.deliver(Self.reply(m, code, toTag: m.toTag))
                    }
                }
                if holdReinvite { heldReinvite = answer } else { answer() }
                return
            }
            if sendTrying { socket.deliver(Self.reply(m, 100)) }
            if challenge && m.header("Authorization") == nil {
                socket.deliver(Self.reply(m, 401, toTag: "chal1", extra: [Self.wwwAuthenticate(next())]))
                return
            }
            if let code = inviteFinal {
                let sdp = answerSdp
                let answer = { [weak socket] in
                    guard let socket = socket else { return }
                    if code == 200 {
                        socket.deliver(Self.reply(m, 200, toTag: "cByBmmry4gpBj", extra: ["Contact: <sip:198.51.100.7:5060;transport=tcp>", "Content-Type: application/sdp", "X-Call-Sid: 208fd2fd"], body: sdp))
                    } else {
                        socket.deliver(Self.reply(m, code, toTag: "fail1"))
                    }
                }
                if holdFinal { heldFinal = answer } else { answer() }
            }
        case "BYE", "UPDATE", "CANCEL":
            socket.deliver(Self.reply(m, 200))
        default:
            break
        }
    }

    private func next() -> String {
        nonce += 1
        return "nonce\(nonce)"
    }

    static func wwwAuthenticate(_ nonce: String) -> String {
        "WWW-Authenticate: Digest realm=\"sbc.example.test\", algorithm=MD5, qop=\"auth\", nonce=\"\(nonce)\""
    }

    /**
     * The challenge to `m` — a 401 with WWW-Authenticate, or a 407 with
     * Proxy-Authenticate — for a test that answers an INVITE itself, at the
     * moment it chooses (`answerByHand` on the engine's rig).
     */
    static func challenge(_ m: SipMessage, _ code: Int = 401, nonce: String = "by-hand") -> String {
        let header = code == 407
            ? "Proxy-Authenticate: Digest realm=\"sbc.example.test\", algorithm=MD5, qop=\"auth\", nonce=\"\(nonce)\""
            : wwwAuthenticate(nonce)
        return reply(m, code, toTag: "chal1", extra: [header])
    }

    /// The answer to an INVITE, as production's 200 carries it: the SBC's Contact, its call id, the trace's SDP.
    static func answer(_ m: SipMessage) -> String {
        reply(m, 200, toTag: "cByBmmry4gpBj", extra: ["Contact: <sip:198.51.100.7:5060;transport=tcp>", "Content-Type: application/sdp", "X-Call-Sid: 208fd2fd"], body: TraceSdp.answer)
    }

    /// A response to `m`, shaped like the SBC's: its Via (with received/rport), From, To (+tag), Call-ID and CSeq.
    static func reply(_ m: SipMessage, _ code: Int, toTag: String? = nil, extra: [String] = [], body: String = "") -> String {
        var out = "SIP/2.0 \(code) \(SipShape.reasons[code] ?? "Whatever")\r\n"
        for via in m.headerValues("Via") { out += "Via: \(via);received=192.0.2.1;rport=65005\r\n" }
        out += "From: \(m.header("From") ?? "")\r\n"
        var to = m.header("To") ?? ""
        if let tag = toTag, m.toTag == nil { to += ";tag=\(tag)" }
        out += "To: \(to)\r\n"
        out += "Call-ID: \(m.callId ?? "")\r\n"
        out += "CSeq: \(m.cseq!.number) \(m.cseq!.method)\r\n"
        for line in extra { out += line + "\r\n" }
        out += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        return out
    }
}

// MARK: - A scripted peer

final class ScriptedMedia: RtcMedia {
    var onIceState: ((RtcIceState) -> Void)?
    var offerResult: Result<String, RtcMediaError>? = .success(TraceSdp.offer)
    var answerError: RtcMediaError?
    private(set) var servers: [RtcIceServer]?
    private(set) var appliedAnswers: [String] = []
    private(set) var reoffers: [Bool] = []
    private(set) var muted: [Bool] = []
    private(set) var closed = false
    var level = RtcInboundAudio(audioLevel: 0, totalAudioEnergy: 0, bytesReceived: 0, packetsReceived: 0, packetsLost: 0, jitter: 0, codec: "audio/PCMU")
    private var pendingOffer: ((Result<String, RtcMediaError>) -> Void)?

    func prepareOffer(iceServers: [RtcIceServer], done: @escaping (Result<String, RtcMediaError>) -> Void) {
        servers = iceServers
        if let result = offerResult { done(result) } else { pendingOffer = done }
    }

    /// Finish an offer the test held back.
    func finishOffer(_ result: Result<String, RtcMediaError> = .success(TraceSdp.offer)) {
        pendingOffer?(result)
        pendingOffer = nil
    }

    /// Hold applyAnswer's completion until the test finishes it (`finishAnswer`): an answer still being applied.
    var holdAnswer = false
    private var pendingAnswer: ((RtcMediaError?) -> Void)?

    func applyAnswer(_ sdp: String, done: @escaping (RtcMediaError?) -> Void) {
        appliedAnswers.append(sdp)
        if holdAnswer { pendingAnswer = done } else { done(answerError) }
    }

    func finishAnswer() {
        pendingAnswer?(answerError)
        pendingAnswer = nil
    }

    func answer(offer sdp: String, done: @escaping (Result<String, RtcMediaError>) -> Void) {
        done(.success("v=0\r\no=- answer\r\n"))
    }

    /// What a re-offer makes (the trace's offer, candidates inside, by default); nil holds it until `finishReoffer`.
    var reofferResult: Result<String, RtcMediaError>? = .success(TraceSdp.offer)
    private var pendingReoffer: ((Result<String, RtcMediaError>) -> Void)?

    func reoffer(iceRestart: Bool, done: @escaping (Result<String, RtcMediaError>) -> Void) {
        reoffers.append(iceRestart)
        if let result = reofferResult { done(result) } else { pendingReoffer = done }
    }

    func finishReoffer(_ result: Result<String, RtcMediaError> = .success(TraceSdp.offer)) {
        pendingReoffer?(result)
        pendingReoffer = nil
    }

    func inboundAudio(_ done: @escaping (RtcInboundAudio?) -> Void) { done(level) }
    func setMuted(_ muted: Bool) { self.muted.append(muted) }
    func close() { closed = true }

    func ice(_ state: RtcIceState) { onIceState?(state) }

    // Weak networks.
    var gatherPace = 1.0
    var gathered = RtcGathered()
    private(set) var forgets = 0
    func forgetGathered() {
        gathered = RtcGathered()
        forgets += 1
    }
    /// What the checks say. By default one pair in progress and nothing answered: neither progress nor "nothing in flight".
    var iceReading: RtcIceReading? = RtcIceReading(pairs: 1, inProgress: 1, requestsSent: 3)
    func iceStats(_ done: @escaping (RtcIceReading?) -> Void) { done(iceReading) }
    private(set) var serverChanges: [(servers: [RtcIceServer], relayOnly: Bool)] = []
    var refusesServers = false
    func useServers(_ servers: [RtcIceServer], relayOnly: Bool) -> Bool {
        serverChanges.append((servers, relayOnly))
        return !refusesServers
    }
}

/// A network the test switches: gone, back, another one.
final class ScriptedNetwork: RtcNetwork {
    var online = true
    private var watchers: [(Bool) -> Void] = []
    func watch(_ changed: @escaping (Bool) -> Void) -> () -> Void {
        watchers.append(changed)
        return {}
    }
    func set(_ value: Bool) {
        online = value
        for watcher in watchers { watcher(value) }
    }
}

final class RecordingAudioControl: RtcAudioControl {
    private(set) var steps: [String] = []
    var directStarts = true
    var restarts = true
    /// What the session would say of a stall (an `audio` row's reason).
    var cause: String?
    func callBegins() { steps.append("begins") }
    func activated() { steps.append("activated") }
    func startDirectly() -> Bool { steps.append("direct"); return directStarts }
    func deactivated() { steps.append("deactivated") }
    func restart() -> Bool { steps.append("restart"); return restarts }
    func stallCause() -> String? { cause }
    /// Who hears the route now (the live call), so a test can move it.
    private(set) var routeWatcher: ((RtcAudioRouteEvent) -> Void)?
    private(set) var routeWatches = 0
    func watchRoute(_ heard: @escaping (RtcAudioRouteEvent) -> Void) -> () -> Void {
        routeWatcher = heard
        routeWatches += 1
        return { [weak self] in self?.routeWatcher = nil }
    }
    func route(_ event: RtcAudioRouteEvent) { routeWatcher?(event) }
    func callEnds() { steps.append("ends") }
}

// MARK: - The call session

final class ScriptedMinting: RtcMinting {
    var outcome: RtcMintOutcome
    private(set) var requests: [(url: URL, body: [String: Any])] = []
    /// Hold the answer until the test releases it.
    var hold = false
    private var held: (() -> Void)?

    init(_ outcome: RtcMintOutcome = .credential(MintFixture.credential)) {
        self.outcome = outcome
    }

    func mint(_ url: URL, body: Data, done: @escaping (RtcMintOutcome) -> Void) {
        requests.append((url, (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]))
        let outcome = self.outcome
        if hold { held = { done(outcome) } } else { done(outcome) }
    }

    func release() {
        held?()
        held = nil
    }
}

enum MintFixture {
    static let credential = RtcCredential(
        server: URL(string: "wss://sbc.example.test:8443")!,
        username: "web-0123456789abcdef",
        password: "pw",
        realm: "sbc.example.test",
        applicationSid: "817361cd-2a13-4937-b465-686d3f58eddd",
        agentId: "agent-webcall-1",
        iceServers: [RtcIceServer(urls: ["stun:stun.example.test:80"], username: nil, credential: nil)],
        expiresAt: Date(timeIntervalSinceNow: 600)
    )

    /// A 200 from the call-session route, shaped as production's (TRACE.md §0).
    static let response = """
    {"server":"wss://sbc.example.test:8443","username":"web-0123456789abcdef","password":"pw",\
    "realm":"sbc.example.test","application_sid":"817361cd-2a13-4937-b465-686d3f58eddd",\
    "client_sid":"cs-1","expires_at":"2026-10-15T00:10:00.123456+00:00",\
    "ice_servers":[{"urls":"stun:stun.relay.example.test:80"},{"urls":["turn:relay.example.test:80","turns:relay.example.test:443?transport=tcp"],"username":"u","credential":"c"}],\
    "agent_id":"agent-webcall-1","direct":{"url":"wss://ignored.example.test"}}
    """
}

// MARK: - The direct mint's network

/**
 * The web route's grant-only mode, the gateway's probe and its direct mint,
 * answered as production answers them (the web route, and the call servers'
 * POST and GET of the direct route) unless the test says
 * otherwise — or held until it releases them. Every request is recorded.
 */
final class ScriptedGateway: RtcHTTP {
    enum Kind: Equatable {
        case grantOnly, probe, direct
    }

    struct Sent {
        let url: URL
        /// The body, read back; nil for a GET.
        let json: [String: Any]?
        let timeout: Double

        var kind: Kind {
            if json == nil { return .probe }
            return json?["grant_only"] as? Bool == true ? .grantOnly : .direct
        }

        var grant: String? { json?["grant"] as? String }
    }

    private(set) var sent: [Sent] = []
    /// Each grant-only request is answered with the next grant (`DirectFixture.grant(1)`, then 2…), unless replaced.
    private(set) var grantsIssued = 0
    var grantOnly: ((Int) -> RtcHTTPAnswer)?
    var probe: RtcHTTPAnswer = .answered(status: 200, data: Data(#"{"direct":true}"#.utf8))
    /// The direct mints' answers, in order; once spent, a credential.
    var direct: [RtcHTTPAnswer] = []
    var holding: Set<Kind> = []
    private var held: [(kind: Kind, answer: () -> Void)] = []

    func send(_ url: URL, json: Data?, timeout: Double, done: @escaping (RtcHTTPAnswer) -> Void) {
        let request = Sent(url: url, json: json.map { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]) ?? [:] }, timeout: timeout)
        sent.append(request)
        let answer: RtcHTTPAnswer
        switch request.kind {
        case .grantOnly:
            grantsIssued += 1
            answer = grantOnly?(grantsIssued) ?? .answered(status: 200, data: DirectFixture.grantOnlyAnswer(grantsIssued))
        case .probe:
            answer = probe
        case .direct:
            answer = direct.isEmpty ? .answered(status: 200, data: Data(MintFixture.response.utf8)) : direct.removeFirst()
        }
        if holding.contains(request.kind) {
            held.append((request.kind, { done(answer) }))
        } else {
            done(answer)
        }
    }

    /// Answer what was held of one kind, in order.
    func release(_ kind: Kind) {
        holding.remove(kind)
        let now = held.filter { $0.kind == kind }
        held.removeAll { $0.kind == kind }
        for item in now { item.answer() }
    }

    func kinds() -> [Kind] { sent.map(\.kind) }
    var directs: [Sent] { sent.filter { $0.kind == .direct } }
}

enum DirectFixture {
    static let base = "https://www.graine.ai"
    static let key = "pk_test_rig"
    static let route = URL(string: "https://gw.example.test/direct/grant-session")!
    /// Production's grant life: fifteen minutes.
    static let ttlMs = 900_000.0
    /// The wall clock the rig starts at (epoch seconds).
    static let wall = 1_792_000_000.0

    static func grant(_ n: Int) -> String { "v1.grant-\(n).sig" }

    /// An offer as the web route writes it (lib/rtc-grant.ts DirectMintOffer).
    static func offerJSON(_ n: Int, ttlMs: Double? = DirectFixture.ttlMs, expiresAtMs: Double = (wall + 900) * 1000) -> [String: Any] {
        var o: [String: Any] = ["grant": grant(n), "expires_at": expiresAtMs, "url": route.absoluteString]
        if let ttl = ttlMs { o["ttl_ms"] = ttl }
        return o
    }

    static func offer(_ n: Int) -> RtcDirectOffer { RtcDirectOffer.parse(offerJSON(n))! }

    static func grantOnlyAnswer(_ n: Int) -> Data {
        try! JSONSerialization.data(withJSONObject: ["direct": offerJSON(n)])
    }

    static func refusal(_ status: Int, _ code: String?, _ detail: String = "No.") -> RtcHTTPAnswer {
        var o: [String: Any] = ["detail": detail]
        if let code = code { o["code"] = code }
        return .answered(status: status, data: try! JSONSerialization.data(withJSONObject: o))
    }

    /**
     * A call's mint body as the core writes it (RtcMintBody): the key, the
     * session, the call's variables, who the customer is — and the call's id
     * when it names one.
     */
    static func body(sessionId: String = "0123456789abcdef0123456789abcdef", customer: String? = "customer-1", memory: Bool = true, callId: String? = nil) -> Data {
        var o: [String: Any] = [
            "publishableKey": key,
            "session_id": sessionId,
            "variables": ["who_called": "customer", "call_reason": "card_blocked"],
            "installId": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            "memory": memory,
            "timezone": "Asia/Kolkata",
        ]
        if let customer = customer { o["identity"] = ["value": customer] }
        if let callId = callId { o["callId"] = callId }
        return try! JSONSerialization.data(withJSONObject: o)
    }
}

/**
 * The direct mint on fakes, shared by the calls a test places one after
 * another: one clock for it and them, the network scripted. The wall clock
 * moves with that clock, plus `skew`: a device set ahead of the server, or a
 * phone that slept (the wall moved, the clock that schedules did not).
 */
final class DirectRig {
    let clock = ManualRtcClock()
    let gateway = ScriptedGateway()
    var skew = 0.0
    private let start: Double
    /// Next-call ids handed out (`call_next1`, `call_next2`…), and ids calls took of their own (`call_own1`…).
    private(set) var nextIds = 0
    private(set) var ownIds = 0
    /// The id the last placed call took.
    private(set) var lastId: String?
    private(set) lazy var mint = RtcDirectMint(
        clock: clock,
        http: gateway,
        wallNow: { [unowned self] in Date(timeIntervalSince1970: DirectFixture.wall + self.skew + (self.clock.now - self.start)) },
        newCallId: { [unowned self] in
            self.nextIds += 1
            return "call_next\(self.nextIds)"
        }
    )

    init() {
        start = clock.now
    }

    /// What the core does when the session arrives, the customer changes or the app comes back: the next call's grant.
    func warm(customer: String? = "customer-1", memory: Bool = true) {
        mint.warm(baseUrl: DirectFixture.base, body: DirectFixture.body(sessionId: "", customer: customer, memory: memory))
    }

    /// What the core does when a call rings: a grant for exactly its id.
    func ring(_ callId: String, customer: String? = "customer-1") {
        mint.warm(baseUrl: DirectFixture.base, body: DirectFixture.body(sessionId: "", customer: customer, callId: callId))
    }

    /// What `GraineCalls.startCall` asks: the next call's id, while its grant is usable.
    func take(customer: String? = "customer-1", memory: Bool = true) -> String? {
        mint.takeCallId(baseUrl: DirectFixture.base, body: DirectFixture.body(sessionId: "", customer: customer, memory: memory))
    }

    /// A call the customer places, as startCall places it: the next call's id when it can take it, else one of its own.
    func place(customer: String? = "customer-1", memory: Bool = true) -> EngineRig {
        let id = take(customer: customer, memory: memory) ?? {
            ownIds += 1
            return "call_own\(ownIds)"
        }()
        lastId = id
        return call(callId: id, customer: customer, memory: memory)
    }

    /// A call with exactly this id (a ring answered, a call placed elsewhere) on this direct mint; `rang`: prepared for a ring.
    func call(callId: String?, customer: String? = "customer-1", memory: Bool = true, rang: Bool = false) -> EngineRig {
        EngineRig(clock: clock, direct: mint, rang: rang) { id in
            DirectFixture.body(sessionId: id, customer: customer, memory: memory, callId: callId)
        }
    }

    /// The agent's next call's id and grant.
    var next: (callId: String?, grant: String)? { mint.nextGrant(baseUrl: DirectFixture.base, publishableKey: DirectFixture.key) }

    /// The grant held for one call — for whoever, or for exactly one customer (nil: nobody known, the anonymous request).
    func grant(for callId: String?) -> String? {
        mint.grant(baseUrl: DirectFixture.base, publishableKey: DirectFixture.key, callId: callId)
    }

    func grant(for callId: String?, customer: String?) -> String? {
        let identity = RtcMintBodyParts(DirectFixture.body(sessionId: "", customer: customer))!.identityKey
        return mint.grant(baseUrl: DirectFixture.base, publishableKey: DirectFixture.key, callId: callId, identity: identity)
    }
}

// MARK: - SDP from the production trace

enum TraceSdp {
    /// Chrome's offer in the trace, as libwebrtc writes it (one candidate of each kind).
    static let offer = [
        "v=0", "o=- 4844249809718397698 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE 0", "a=extmap-allow-mixed",
        "a=msid-semantic: WMS c59da79a", "m=audio 51750 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126", "c=IN IP4 203.0.113.9",
        "a=rtcp:9 IN IP4 0.0.0.0",
        "a=candidate:1220794126 1 udp 2122194688 192.0.2.10 65463 typ host generation 0 network-id 1 network-cost 10",
        "a=candidate:2263966376 1 udp 58598144 203.0.113.9 51750 typ relay raddr 192.0.2.10 rport 65463 generation 0 network-id 1",
        "a=ice-ufrag:gC1e", "a=ice-pwd:abcdefghijklmnopqrstuvwx", "a=ice-options:trickle",
        "a=fingerprint:sha-256 43:5F:4D:F5:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB",
        "a=setup:actpass", "a=mid:0", "a=sendrecv", "a=rtcp-mux", "a=rtcp-rsize",
        "a=rtpmap:111 opus/48000/2", "a=rtcp-fb:111 transport-cc", "a=fmtp:111 minptime=10;useinbandfec=1",
        "a=rtpmap:63 red/48000/2", "a=fmtp:63 111/111", "a=rtpmap:9 G722/8000", "a=rtpmap:0 PCMU/8000", "a=rtpmap:8 PCMA/8000",
        "a=rtpmap:13 CN/8000", "a=rtpmap:110 telephone-event/48000", "a=rtpmap:126 telephone-event/8000", "",
    ].joined(separator: "\r\n")

    /// The SBC's answer in the trace: PCMU and telephone-event/8000, full ICE, one host candidate, setup:active, no BUNDLE.
    static let answer = [
        "v=0", "o=Media-Server 1791980511 1791980512 IN IP4 198.51.100.7", "s=Media-Server", "t=0 0",
        "m=audio 40414 UDP/TLS/RTP/SAVPF 0 126", "c=IN IP4 198.51.100.7", "a=mid:0",
        "a=rtpmap:0 PCMU/8000", "a=rtpmap:126 telephone-event/8000", "a=fmtp:126 0-15", "a=sendrecv",
        "a=rtcp:40414", "a=rtcp-mux", "a=setup:active",
        "a=fingerprint:sha-256 6E:0F:6A:86:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67",
        "a=tls-id:971c16c527f442e59dc2001a9d8e8959", "a=ptime:20", "a=ice-ufrag:DLtsxRNa", "a=ice-pwd:abcdefghijklmnopqrstuvwx",
        "a=ice-options:trickle", "a=candidate:IEr81xVVpfGHdWH2 1 UDP 2130706431 198.51.100.7 40414 typ host",
        "a=end-of-candidates", "",
    ].joined(separator: "\r\n")
}

// MARK: - A real WebSocket server on this machine, speaking SIP

/**
 * A WebSocket server on 127.0.0.1 (Network.framework) that accepts the "sip"
 * subprotocol, as the SBC does: the SIP user agent is tested over the real
 * URLSession socket it uses in an app, against a server the test scripts.
 */
final class LocalSipServer {
    let queue = DispatchQueue(label: "ai.graine.tests.sip-server")
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var log: [String] = []
    /// The script: what the server does with each message (on the server's queue).
    var handle: (SipMessage, @escaping (String) -> Void) -> Void = { _, _ in }
    private let asked: Asked
    var protocolsAsked: [String] { asked.all }
    private(set) var closes: [String] = []

    /// The subprotocols clients asked for, from the handshake handler's queue.
    final class Asked {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ protocols: [String]) {
            lock.lock()
            items += protocols
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    init() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        // Before the listener is made: the parameters carry the options as they are then.
        let asked = Asked()
        self.asked = asked
        ws.setClientRequestHandler(queue) { protocols, _ in
            asked.add(protocols)
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: protocols.contains("sip") ? "sip" : nil, additionalHeaders: nil)
        }
        let parameters = NWParameters(tls: nil)
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    /// `ws://127.0.0.1:{port}`, built so no address is written into the package as text.
    var url: URL {
        var parts = URLComponents()
        parts.scheme = "ws"
        parts.host = "127.0.0.1"
        parts.port = Int(port)
        return parts.url!
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        for connection in open { connection.cancel() }
    }

    /// Every message the client sent, in order.
    var received: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var receivedMessages: [SipMessage] { received.compactMap { SipParser.parse($0) } }

    /// Send to the newest connection (anything — a request, garbage).
    func push(_ text: String) {
        lock.lock()
        let connection = connections.last
        lock.unlock()
        if let connection = connection { send(text, on: connection) }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                self.lock.lock()
                self.closes.append("close \(metadata.closeCode)")
                self.lock.unlock()
                return
            }
            if let data = data, let text = String(data: data, encoding: .utf8) {
                self.lock.lock()
                self.log.append(text)
                self.lock.unlock()
                if let message = SipParser.parse(text) {
                    self.handle(message) { [weak self] reply in self?.send(reply, on: connection) }
                }
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

/// Wait (polling) until `condition` holds, for at most `seconds`.
func eventually(_ seconds: Double = 5, _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
