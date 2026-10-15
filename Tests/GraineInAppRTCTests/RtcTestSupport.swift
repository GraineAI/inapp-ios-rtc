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
    private var nonce = 0

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
                // A re-INVITE (an ICE restart): answered at once.
                socket.deliver(Self.reply(m, 200, toTag: m.toTag, extra: ["Contact: <sip:198.51.100.7:5060;transport=tcp>", "Content-Type: application/sdp"], body: answerSdp))
                return
            }
            if sendTrying { socket.deliver(Self.reply(m, 100)) }
            if challenge && m.header("Authorization") == nil {
                socket.deliver(Self.reply(m, 401, toTag: "chal1", extra: [Self.wwwAuthenticate(next())]))
                return
            }
            if let code = inviteFinal {
                if code == 200 {
                    socket.deliver(Self.reply(m, 200, toTag: "cByBmmry4gpBj", extra: ["Contact: <sip:198.51.100.7:5060;transport=tcp>", "Content-Type: application/sdp", "X-Call-Sid: 208fd2fd"], body: answerSdp))
                } else {
                    socket.deliver(Self.reply(m, code, toTag: "fail1"))
                }
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

    func applyAnswer(_ sdp: String, done: @escaping (RtcMediaError?) -> Void) {
        appliedAnswers.append(sdp)
        done(answerError)
    }

    func answer(offer sdp: String, done: @escaping (Result<String, RtcMediaError>) -> Void) {
        done(.success("v=0\r\no=- answer\r\n"))
    }

    func reoffer(iceRestart: Bool, done: @escaping (Result<String, RtcMediaError>) -> Void) {
        reoffers.append(iceRestart)
        done(.success(TraceSdp.offer))
    }

    func inboundAudio(_ done: @escaping (RtcInboundAudio?) -> Void) { done(level) }
    func setMuted(_ muted: Bool) { self.muted.append(muted) }
    func close() { closed = true }

    func ice(_ state: RtcIceState) { onIceState?(state) }
}

final class RecordingAudioControl: RtcAudioControl {
    private(set) var steps: [String] = []
    var directStarts = true
    func callBegins() { steps.append("begins") }
    func activated() { steps.append("activated") }
    func startDirectly() -> Bool { steps.append("direct"); return directStarts }
    func deactivated() { steps.append("deactivated") }
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
