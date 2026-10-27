@_spi(GraineRTC) import GraineInApp
import Foundation

/*
 * ONE CALL ON WEBRTC — exactly the voice bar's sequence, in the app's own
 * process, under CallKit.
 *
 *   prepare   a session id; the call session minted (with the same identity
 *             and variables the call's ticket carries) — at the telephony
 *             gateway with a grant asked for exactly this call when one is in
 *             hand, else on the web route; then, side by side, the peer
 *             gathering its candidates and the SIP socket registering
 *   begin     the control channel opens (the server holds it until the call
 *             exists) and, once the mint has answered, the attempt's budget
 *             starts: 12 s to media, or the call is the WebSocket's
 *   audio     CallKit activated the session (or, failing that, it was started
 *             directly): only now does the INVITE leave, so the greeting is
 *             never played into a session that is not running
 *   dial      INVITE with X-Graine-Session-Id, X-Graine-Agent-Id and
 *             X-Application-Sid; no reply within the link's own pace, or no
 *             answer within 15 s, and the dial has failed — a network-ish
 *             failure gets one more dial on a fresh connection (the link's own
 *             failures, and a 491, a third), never into no network; anything
 *             else goes to the WebSocket. UDP that looked blocked: the next
 *             dial gathers only the relays over TCP and TLS
 *   answered  the media path kept by RtcMediaRecovery: waited for 8 s × the
 *             link's pace (longer while it is still making progress), then an
 *             ICE restart inside the call — never a new call — and the
 *             WebSocket only once that has failed, never before the deadline
 *   live      the media watched (RtcMediaRecovery): a path lost is restarted
 *             3 s in (at once on failed), never into no network — offline time
 *             is not counted — and the call is dropped only after 15 s × pace
 *             with a network, or 30 s without one. While it is lost the call is
 *             `reconnecting` (the call screen's moment); the receiver's level
 *             is reported five times a second
 *   playout   the speaker watched too (`watchPlayout`): the audio activated
 *             and the phone's playout running steadily (0.3 s), the control
 *             channel hears {"type":"audio","state":"ready"} — the agent's
 *             greeting waits for it, and it is said again when the audio
 *             comes back after it was lost; audio arriving with nothing played for 2 s, the
 *             phone's audio is started again, once; still nothing 3 s on,
 *             and the call cannot be heard (`playoutFailed`). A route that
 *             moves (a Bluetooth headset or car kit, the speaker) or an
 *             interruption is given 4 s to settle before anything is judged
 *
 * Before any media: every failure is `unreachable` with the voice bar's
 * reason, and the SDK carries the call on the WebSocket inside the same
 * system call. After it: never — a dropped call is a dropped call.
 */
final class RtcCallEngine: GraineRtcCall {
    /// Everything the engine stands on, handed in so a Mac can stand in for the network and the media.
    struct Parts {
        var clock: RtcClock
        var sockets: RtcSocketFactory
        var minting: RtcMinting
        var random: SipRandom
        var makeMedia: (RtcClock) -> RtcMedia
        var audio: RtcAudioControl
        var now: () -> Date = Date.init
        /// The credential from the telephony gateway, with a grant (Engine/RtcDirectMint.swift); nil: the web route only.
        var direct: RtcDirectMint? = nil
        /// Whether the phone has a network, and when that changes (Engine/RtcNetwork.swift).
        var network: RtcNetwork = SteadyRtcNetwork()

        static func production() -> Parts {
            #if os(iOS)
            let audio: RtcAudioControl = RtcAudioGate.shared
            #else
            let audio: RtcAudioControl = NoAudioControl()
            #endif
            return Parts(
                clock: DispatchRtcClock(),
                sockets: URLSessionRtcSocketFactory(),
                minting: URLSessionRtcMinting(),
                random: SystemSipRandom(),
                makeMedia: { WebRTCMedia(clock: $0) },
                audio: audio,
                direct: RtcDirectMint.shared,
                network: PathRtcNetwork()
            )
        }
    }

    /// The agent is audible above this level, and quiet once below `quietLevel` for `quietSeconds`.
    static let speakingLevel = 0.02
    static let quietLevel = 0.01
    static let quietSeconds = 0.5
    /// Five readings a second.
    static let levelSeconds = 0.2
    /// The audio so far goes up to the SDK about this often (GraineRtcEvent.audio).
    static let audioReportSeconds = 1.0
    /// Audio arriving with nothing played this long: the phone's audio is started again, once.
    static let playoutStallSeconds = 2.0
    /**
     * The audio is said ready (the agent's greeting waits for it) only once its playout has run this long, steadily,
     * with the call's audio on. A deactivation that lands just after the audio started — the call before's, on a
     * redial within a second — is seen before the greeting goes, not after it is cut.
     */
    static let readyStableSeconds = 0.3
    /// Still nothing played this long after that restart: the call cannot be heard.
    static let playoutFailAfter = 3.0
    /// After the route moves (a Bluetooth headset or car kit's hands-free link can take seconds), nothing is judged this long.
    static let routeSettleSeconds = 4.0
    /// At most this many `route_changed` rows per call: a flapping headset says enough by then.
    static let routeRowsMax = 8

    private enum Phase: Int, Comparable {
        case idle, preparing, ready, dialing, answered, live, ended
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    private let request: GraineRtcRequest
    private let parts: Parts
    private let clock: RtcClock
    let sessionId: String

    // Event delivery: kept until somebody listens.
    private let sinkLock = NSLock()
    private var sink: ((GraineRtcEvent) -> Void)?
    private var held: [GraineRtcEvent] = []
    private var silenced = false
    /// Who hears, while the call is prepared ahead of its dial, that it is ready or lost (`onPrepared`).
    private var preparedSink: ((GraineRtcPreparedState) -> Void)?

    // Everything below is touched on the clock only.
    private var phase = Phase.idle
    private var control: RtcControlChannel?
    private var credential: RtcCredential?
    /// The credential came from the telephony gateway (for the prepared report).
    private var mintedDirect = false
    /// The audio gate was taken (`callBegins`): released exactly once, by the leg that took it.
    private var audioTaken = false
    /// Prepared ahead of the tap, and the transport row to send at media — said by the call that dials it; under `sinkLock`.
    private var aheadOfTap = false
    private var openingRow: String?
    // For the analytics rows (GraineCallTelemetry): ready when it was begun, the last INVITE, the first
    // registration, a heal under way, the media's numbers.
    private var readyAtTap = false
    private var lastInviteAt: Double?
    private var firstRegisterMs: Double?
    private var healing: (what: String, since: Double)?
    private var sipLostAt: Double?
    private var qualitySent = false
    /// The `ended` row went: once per call.
    private var endedSent = false
    private var quality = RtcQualitySamples()
    /// When the audio so far last went up to the SDK.
    private var audioReportedAt: Double?
    private var media: RtcMedia?
    private var offer: String?
    private var ua: SipUserAgent?
    private var uaGeneration = 0
    private var registered = false
    private var registerSeconds: Double?
    private var registerTimer: RtcTimer?
    private var begun = false
    private var audioOn = false
    private var muted = false
    private var dials = 0
    private var dialSeq = 0
    /// The INVITE in flight has had a reply: a provisional one, or its answer. A challenge is not one — it replaces the INVITE.
    private var heard = false
    private var heardArmed = false
    private var redialing = false
    /// The mint's refusal was cured once (APP-IDENTITY.md §2.3): a second one stands.
    private var cureTried = false
    private var freshConnections = 0
    private var budgetTimer: RtcTimer?
    private var heardTimer: RtcTimer?
    /// The ceiling: `DialRules.answerDeadline` from the dial, whatever it heard.
    private var answerTimer: RtcTimer?
    /// `DialRules.answerAfterHeard` from the first provisional reply to the INVITE in flight; stopped by a challenge.
    private var answerClock: RtcTimer?
    private var iceState = RtcIceState.new
    private var levelTimer: RtcTimer?
    // WEAK NETWORKS (RtcMediaRecovery, RtcResilience).
    /// The answered dial's media path, kept inside WebRTC; nil before an answer and after the end.
    private var recovery: RtcMediaRecovery?
    /// When the current dial was answered: the budget never cuts a setup the recovery still works on before this + 30 s.
    private var answeredAt: Double?
    private var budgetArmedAt: Double?
    /// The call's own media round trip (seconds), for the link's pace.
    private var mediaRoundTrip: Double?
    private var networkUnwatch: (() -> Void)?
    /// A redial waiting for the network: woken by its return (true), a hang-up or its deadline (false).
    private var networkWaiter: ((Bool) -> Void)?
    private var networkWaitTimer: RtcTimer?
    /// A restart's offer or re-INVITE is out: no second one until it settles.
    private var restartOut = false
    /// The peer gathers through the relays alone because THIS engine put it there: only that is ever lifted.
    private var relayOnlyByUs = false
    /// The next dial is made on the relays over TCP and TLS alone (this dial's UDP looked blocked); its offer is being made.
    private var relayOnlyNextDial = false
    private var offerStale = false
    private var speaking = false
    /// The live path was lost and is being brought back: what the call screen shows as "Reconnecting".
    private var reconnecting = false
    private var quietSince: Double?
    /// How this call's audio was activated, for its `audio` rows: by CallKit, started directly, or not yet.
    private var audioVia = "none"
    /// The system took the audio back once the call was under way, and has not given it back: a direct start now is that deactivation's rescue.
    private var deactivatedLive = false
    // THE PLAYOUT WATCH (`watchPlayout`): the last reading's counters and when it was, how long audio has arrived with
    // nothing played, the restart, and whether the audio was said ready — or the call said unheard.
    private var lastPlayout: (samples: Int?, playout: Int?, packets: Int, at: Double)?
    private var unplayedFor = 0.0
    private var stillFor = 0.0
    private var playoutRestartedAt: Double?
    private var audioReady = false
    private var playoutFailed = false
    /// Since when the playout counts have moved in every reading with this call's audio on: the audio is said ready
    /// only once that has lasted `readyStableSeconds`. Nil until they move, and again whenever they stop or the audio goes.
    private var playingSince: Double?
    /// When this call's audio last came on (CallKit, a direct start, a restart): a steady stretch never starts before it.
    private var audioOnSince: Double?
    /// Ready was said, then the audio was lost — taken back, or stalled and restarted: it is said again once it plays
    /// steadily, with why (its `audio` row's reason). Nil otherwise.
    private var readyAgainBecause: String?
    // THE ROUTE (`routeEvent`): what stops hearing it, until when the watch stands aside, whether the system holds the
    // audio, and the route rows said so far (and the last kind said).
    private var routeUnwatch: (() -> Void)?
    private var settleUntil: Double?
    private var interrupted = false
    private var routeRows = 0
    private var lastRoute: String?
    /// Times of each step, for the log and the live test.
    private(set) var marks: [String: Double] = [:]
    private var startedAt: Double = 0

    init(request: GraineRtcRequest, parts: Parts) {
        self.request = request
        self.parts = parts
        self.clock = parts.clock
        self.sessionId = parts.random.sessionId()
    }

    // MARK: - GraineRtcCall

    var onEvent: ((GraineRtcEvent) -> Void)? {
        get {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            return sink
        }
        set {
            sinkLock.lock()
            sink = newValue
            sinkLock.unlock()
            clock.run { [weak self] in self?.flush() }
        }
    }

    var onPrepared: ((GraineRtcPreparedState) -> Void)? {
        get {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            return preparedSink
        }
        set {
            sinkLock.lock()
            preparedSink = newValue
            sinkLock.unlock()
        }
    }

    var preparedAhead: Bool {
        get {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            return aheadOfTap
        }
        set {
            sinkLock.lock()
            aheadOfTap = newValue
            sinkLock.unlock()
        }
    }

    var transportRow: String? {
        get {
            sinkLock.lock()
            defer { sinkLock.unlock() }
            return openingRow
        }
        set {
            sinkLock.lock()
            openingRow = newValue
            sinkLock.unlock()
        }
    }

    func prepare() {
        clock.run { [self] in
            guard phase == .idle else { return }
            phase = .preparing
            startedAt = clock.now
            // Nothing touches the microphone until CallKit hands the audio over.
            parts.audio.callBegins()
            audioTaken = true
            let channel = RtcControlChannel(host: request.controlHost, sessionId: sessionId, clock: clock, sockets: parts.sockets, log: { [weak self] in self?.trace($0) })
            channel.onFrame = { [weak self] text in self?.emit(.control(text)) }
            channel.onJoined = { [weak self] joined in
                self?.mark(joined ? "control_ready" : "control_lost")
                self?.trace(joined ? "control: joined" : "control: lost")
            }
            control = channel
            // The network, for the recovery's rules: changes hop onto the clock.
            networkUnwatch = parts.network.watch { [weak self] online in self?.clock.run { self?.networkChanged(online) } }
            mint()
        }
    }

    func begin() {
        clock.run { [self] in
            guard !begun, phase != .ended else { return }
            begun = true
            mark("begin")
            // Set up and registered before the tap — a prepared call's connect row says so.
            readyAtTap = phase == .ready && !redialing
            control?.open()
            // The attempt's budget runs from the mint's answer: a slow mint is the web's wait, not WebRTC's.
            if credential != nil { armBudget() }
            dialIfReady()
        }
    }

    /// WebRTC's budget — mint to media — once the call is wanted and its credential is in hand; once per call.
    private func armBudget() {
        guard begun, budgetTimer == nil, phase < .live else { return }
        budgetArmedAt = clock.now
        budgetTimer = clock.after(request.budgetSeconds) { [weak self] in self?.budgetSpent() }
    }

    func audioActivated() {
        clock.run { [self] in
            guard phase != .ended else { return }
            parts.audio.activated()
            audioCameOn()
            audioVia = "callkit"
            deactivatedLive = false
            mark("audio")
            dialIfReady()
        }
    }

    func startAudioDirectly(_ done: @escaping (Bool) -> Void) {
        clock.run { [self] in
            guard phase != .ended else { return done(false) }
            if audioOn { return done(true) }
            let started = parts.audio.startDirectly()
            if started {
                audioCameOn()
                mark("audio")
                trace("audio: started without CallKit")
                // CallKit never activated it — or took it back once the call was under way.
                audioVia = "direct"
                sendAudioRow("rescued", reason: deactivatedLive ? "deactivated" : "no_activation")
                deactivatedLive = false
                dialIfReady()
            }
            done(started)
        }
    }

    func audioDeactivated() {
        clock.run { [self] in
            guard phase != .ended else { return }
            parts.audio.deactivated()
            audioOn = false
            playingSince = nil
            // Once the call is under way: an interruption, not its end — the SDK starts the audio again if CallKit does not.
            guard phase >= .dialing else { return }
            deactivatedLive = true
            // Said ready already: whatever played since may not have been heard — said again once it plays.
            if audioReady { readyAgainBecause = "deactivated" }
            sendAudioRow("deactivated_live", reason: nil)
        }
    }

    /// The call's audio is on — from now, when it was off: a steady stretch of playout is counted from here.
    private func audioCameOn() {
        if !audioOn {
            audioOnSince = clock.now
            playingSince = nil
        }
        audioOn = true
    }

    func setMuted(_ value: Bool) {
        clock.run { [self] in
            muted = value
            media?.setMuted(value)
        }
    }

    func sendControl(_ frame: String, kind: String?) {
        clock.run { [self] in control?.send(frame, kind: kind) }
    }

    func sendEnded(cause: String) {
        clock.run { [self] in
            guard phase != .ended else { return }
            // As Android's leg: the call's quality row, then how it ended — both before the BYE.
            if phase == .live { sendQualityRow() }
            sendEndedRow(cause)
        }
    }

    func hangUp() {
        clock.run { [self] in
            guard phase != .ended else { return }
            // Nothing is reported after a hang-up, not even to the log: the caller has moved on (its connection report
            // keeps the audio it was last handed).
            silence()
            // The call's quality row goes before the BYE, on the channel still open; best effort, never waited for.
            if phase == .live { sendQualityRow() }
            release(sendBye: true)
        }
    }

    // MARK: - The call session

    /**
     * THE GATEWAY FIRST, THE WEB ROUTE SECOND — the voice bar's order. A call
     * holding a grant asked for exactly it (its agent, its customer, its id)
     * takes it straight to the telephony gateway; the answer is the
     * credential, a gate's refusal, or "the web route", which is then asked as
     * before. Each failure of the direct mint costs one short request and
     * nothing else.
     */
    /**
     * What the call session needs first is made ready by the core
     * (`beforeMint`: a proof of the app the agent requires, an identity token
     * about to expire) — then the mint, with its body read only then.
     */
    private func mint() {
        guard let before = request.beforeMint else { return mintNow() }
        before { [weak self] in
            self?.clock.run {
                guard let self = self, self.phase == .preparing || self.redialing else { return }
                self.mintNow()
            }
        }
    }

    private func mintNow() {
        var base = request.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/embed/rtc-session") else {
            return giveUp(.mintFailed, "the base URL is not a URL")
        }
        mark("mint_sent")
        let body = request.mintBody(sessionId)
        guard let direct = parts.direct else {
            return mintOnWebRoute(url, base: base, body: body)
        }
        direct.mint(baseUrl: base, body: body, tokens: request.clientTokens) { [weak self] answer in
            self?.clock.run {
                guard let self = self, self.phase == .preparing || self.redialing else { return }
                switch answer {
                case .minted(let outcome):
                    self.minted(outcome, at: "the gateway")
                case .webRoute(let why):
                    self.trace("direct mint: \(why) — minting on the web route")
                    self.mintOnWebRoute(url, base: base, body: body)
                }
            }
        }
    }

    /**
     * `POST {baseUrl}/api/embed/rtc-session`: every check on the way, and a
     * grant back beside the credential. With server tokens in play the body
     * carries the agent's newest token, and a refusal a fresh one can lift is
     * sent once more with it (GraineRtcTokens) — never in `body`, which is what
     * the grant is kept for.
     */
    private func mintOnWebRoute(_ url: URL, base: String, body: Data) {
        let minting = parts.minting
        let answered: (RtcMintOutcome) -> Void = { [weak self] outcome in
            self?.clock.run {
                guard let self = self else { return }
                if case .credential(let credential) = outcome {
                    if let offer = credential.direct {
                        // The grant beside the credential is this call's own: a redial's mint takes it to the gateway.
                        self.parts.direct?.accept(offer, baseUrl: base, body: body)
                    } else if self.request.rang {
                        // A call that rang, and its answer brought no grant: one asked for on its own, for a later mint of it.
                        self.parts.direct?.warm(baseUrl: base, body: body, tokens: self.request.clientTokens)
                    }
                }
                self.minted(outcome, at: nil)
            }
        }
        guard let tokens = request.clientTokens else { return minting.mint(url, body: body, done: answered) }
        tokens.send(body, refreshable: { (outcome: RtcMintOutcome) in
            guard case let .refused(_, code, _) = outcome else { return false }
            return GraineRtcTokens.refreshable(code)
        }, send: { json, answer in
            minting.mint(url, body: json, done: answer)
        }, done: answered)
    }

    private func minted(_ outcome: RtcMintOutcome, at place: String?, reported: Bool = false) {
        guard phase == .preparing || redialing else { return }
        // What the call session said of the app and the user, for the core to keep (its passes, `verification`).
        if !reported {
            switch outcome {
            case .credential(let credential):
                request.mintAnswered?(200, credential.verification.map { Data(#"{"verification":"#.utf8) + $0 + Data("}".utf8) })
            case let .refused(status, code, _):
                request.mintAnswered?(status, code.flatMap { try? JSONSerialization.data(withJSONObject: ["code": $0]) })
            case .unreachable:
                break
            }
        }
        if case let .refused(_, code?, _) = outcome, GraineRtcRefusal.curable.contains(code), !cureTried, let cure = request.cure {
            // A refusal the core can cure — the app proven, a fresh identity token — and the mint made once more.
            cureTried = true
            trace("the call session asked for \(code): curing it once")
            cure(code) { [weak self] retry in
                self?.clock.run {
                    guard let self = self, self.phase == .preparing || self.redialing else { return }
                    if retry { return self.mintNow() }
                    self.minted(outcome, at: place, reported: true)
                }
            }
            return
        }
        if case let .refused(_, code?, message) = outcome, GraineRtcRefusal.ends(code) {
            // A gate said no to the call itself, this app was refused, or the web route refused its server token or
            // key: it ends here, in their words — no fallback (the WebSocket would meet the same answer).
            trace("refused by the call session: \(code)")
            release(sendBye: false)
            emit(.refused(code: code, message: message ?? ""))
            notePrepared(.lost)
            return
        }
        guard case .credential(let credential) = outcome else {
            return giveUp(.mintFailed, outcome.detail)
        }
        mintedDirect = place != nil
        mark("minted")
        trace("minted\(place.map { " at \($0)" } ?? "") in \(ms(since: "mint_sent")) ms (\(credential.iceServers.count) ICE server(s))")
        self.credential = credential
        armBudget()
        if media == nil { startMedia(credential) }
        connectSip(credential)
    }

    private func startMedia(_ credential: RtcCredential) {
        let made = parts.makeMedia(clock)
        media = made
        made.setMuted(muted)
        made.onIceState = { [weak self] state in self?.clock.run { self?.iceChanged(state) } }
        made.prepareOffer(iceServers: credential.iceServers) { [weak self] result in
            self?.clock.run { self?.offerMade(result) }
        }
    }

    private func offerMade(_ result: Result<String, RtcMediaError>) {
        guard phase == .preparing || phase == .ready else { return }
        switch result {
        case .success(let sdp):
            offer = sdp
            mark("offer")
            trace("offer ready after \(ms(since: "minted")) ms")
            becomeReady()
        case .failure(let error):
            giveUp(.error, "the offer could not be made: \(error)")
        }
    }

    // MARK: - SIP

    private func connectSip(_ credential: RtcCredential) {
        uaGeneration += 1
        let generation = uaGeneration
        registered = false
        let identity = SipUserAgent.identity(
            username: credential.username,
            realm: credential.realm,
            password: credential.password,
            userAgent: SipShape.userAgent(sdkVersion: request.sdkVersion),
            random: parts.random
        )
        let agent = SipUserAgent(
            server: credential.server,
            identity: identity,
            clock: clock,
            sockets: parts.sockets,
            random: parts.random,
            log: { [weak self] in self?.trace($0) },
            onEvent: { [weak self] event in
                guard let self = self, generation == self.uaGeneration else { return }
                self.sip(event)
            }
        )
        ua = agent
        registerTimer?.cancel()
        registerTimer = clock.after(DialRules.registerDeadline) { [weak self] in
            guard let self = self, generation == self.uaGeneration, !self.registered, self.phase < .live else { return }
            self.giveUp(.registerFailed, "the registration was not answered within \(Int(DialRules.registerDeadline)) s")
        }
        mark("sip_connect")
        agent.start()
    }

    private func sip(_ event: SipUserAgent.Event) {
        switch event {
        case .connected:
            mark("sip_open")
            // The SIP socket came back under an answered call: replaced.
            if let lost = sipLostAt, phase >= .answered {
                sipLostAt = nil
                sendRecoveryRow("socket_replaced", since: lost)
            }

        case .registered(let seconds):
            registered = true
            registerSeconds = seconds
            registerTimer?.cancel()
            mark("registered")
            trace("registered in \(Int(seconds * 1000)) ms")
            redialing = false
            if firstRegisterMs == nil { firstRegisterMs = seconds * 1000 }
            if let heal = healing, heal.what == "socket_replaced" {
                healing = nil
                sendRecoveryRow("socket_replaced", since: heal.since)
            }
            // A fresh connection made before the offer was ready waits for it like the first one did.
            if phase == .preparing {
                becomeReady()
            } else {
                phase = .ready
                dialIfReady()
            }

        case .registrationFailed(let failure):
            guard phase < .live else { return }
            giveUp(.registerFailed, "the registration was refused (\(describe(failure)))")

        case .transportLost(let detail):
            trace("sip: socket lost (\(detail))")
            // A call prepared ahead whose socket dropped is let go by whoever prepared it; the tap prepares afresh.
            if !begun, phase == .preparing || phase == .ready { notePrepared(.lost) }
            switch phase {
            case .preparing, .ready:
                // Before the dial: one fresh connection, as a dead warm socket gets one in the voice bar.
                if healing == nil { healing = ("socket_replaced", clock.now) }
                freshConnection(after: "the SIP socket closed (\(detail))", fallback: .registerFailed)
            case .answered:
                ua?.keepsTransport = true
                sipLostAt = sipLostAt ?? clock.now
            case .live:
                sipLostAt = sipLostAt ?? clock.now
            default:
                break
            }

        case .inviteSent:
            guard phase == .dialing, !heardArmed else { return }
            heardArmed = true
            mark("invite")
            lastInviteAt = clock.now
            let seq = dialSeq
            // Silence is judged on the INVITE in flight when the deadline comes: after a challenge, the one with credentials.
            heardTimer = clock.after(DialRules.heardDeadline(registerSeconds: registerSeconds)) { [weak self] in
                guard let self = self, seq == self.dialSeq, self.phase == .dialing, !self.heard else { return }
                self.dialFailed(cause: "no_response", code: nil)
            }

        case .heard(let code):
            guard phase == .dialing else { return }
            if !heard { mark("heard") }
            heard = true
            trace("dial: \(code)")
            // THE ANSWER CLOCK. The SBC has the INVITE in flight: still only "trying" DialRules.answerAfterHeard after
            // its first provisional reply is a stuck dial, cancelled and dialled once more on a fresh connection while
            // the attempt's budget still has room. Started once per INVITE — `.challenged` stops it, and the INVITE
            // with credentials starts it again from its own reply. An answer that has arrived is never stuck:
            // `.answered` comes as the 200 is read, before its SDP is applied, and stops it.
            if answerClock == nil {
                let seq = dialSeq
                // Exactly half a second on a good link; longer only on a link measured to be slow.
                answerClock = clock.after(DialRules.answerAfterHeard(pace: pace())) { [weak self] in
                    guard let self = self, seq == self.dialSeq, self.phase == .dialing else { return }
                    self.answerClock = nil
                    self.dialFailed(cause: "no_answer", code: nil)
                }
            }

        case .challenged(let code):
            guard phase == .dialing else { return }
            // Refused for its credentials and sent again with them: nothing heard so far was the INVITE now in flight.
            let after = Int(((clock.now - (lastInviteAt ?? clock.now)) * 1000).rounded())
            trace("dial: challenged (\(code)) after \(after) ms — sent again with credentials, the answer timed from its own reply")
            heard = false
            answerClock?.cancel()
            answerClock = nil

        case let .answered(sdp, callSid):
            guard phase == .dialing, let media = media else { return }
            heardTimer?.cancel()
            answerTimer?.cancel()
            answerClock?.cancel()
            answerClock = nil
            phase = .answered
            mark("answered")
            answeredAt = clock.now
            trace("answered in \(ms(since: "invite")) ms\(callSid.map { " (call \($0))" } ?? "")")
            // From here the BYE needs this socket: a lost one is reconnected, not abandoned.
            ua?.keepsTransport = true
            // The media path is kept inside WebRTC first: waited for, restarted inside this call, then the WebSocket.
            recovery?.dispose()
            let kept = RtcMediaRecovery(host: self, clock: clock)
            recovery = kept
            kept.answered()
            media.applyAnswer(sdp) { [weak self] error in
                guard let self = self, self.phase == .answered else { return }
                if let error = error {
                    self.giveUp(.error, "\(error)")
                } else if self.iceState == .connected || self.iceState == .completed {
                    self.goLive()
                }
            }

        case .inviteFailed(let failure):
            guard phase == .dialing else { return }
            dialFailed(cause: failure.cause, code: failure.code)

        case .byeReceived:
            if phase == .live {
                end(.remote)
            } else if phase < .live {
                // Hung up before any audio: nothing was heard, so the WebSocket may still carry it.
                giveUp(.error, "the call was ended before its audio connected")
            }

        case let .offerReceived(sdp, reply):
            guard let media = media else { return reply(.failure(.connection)) }
            media.answer(offer: sdp) { result in
                reply(result.mapError { _ in SipUserAgent.Failure(code: 488, cause: SipCauses.incompatibleSdp) })
            }

        case .offerRequested(let reply):
            guard let media = media else { return reply(.failure(.connection)) }
            media.reoffer(iceRestart: false) { result in
                reply(result.mapError { _ in SipUserAgent.Failure(code: 500, cause: SipCauses.webrtcError) })
            }

        case .answerInAck(let sdp):
            media?.applyAnswer(sdp) { [weak self] error in
                if let error = error { self?.trace("their answer in the ACK was refused: \(error)") }
            }

        case .dialogLost(let why):
            if phase == .live {
                end(.dropped("the call's signalling was lost (\(why))"))
            } else if phase < .live {
                giveUp(.error, "the call's signalling was lost (\(why))")
            }
        }
    }

    // MARK: - The dial

    private func becomeReady() {
        guard phase == .preparing, offer != nil, registered else { return }
        phase = .ready
        mark("ready")
        trace("ready in \(ms(since: nil)) ms")
        emit(.ready)
        notePrepared(.ready(milliseconds: ms(since: nil), direct: mintedDirect))
        dialIfReady()
    }

    private func dialIfReady() {
        guard phase == .ready, begun, audioOn, !redialing, !offerStale, let offer = offer, let ua = ua, let credential = credential else { return }
        phase = .dialing
        dials += 1
        dialSeq += 1
        heard = false
        heardArmed = false
        let seq = dialSeq
        let target = "sip:app-\(credential.applicationSid)@\(credential.realm)"
        let headers = [
            "X-Graine-Session-Id: \(sessionId)",
            "X-Graine-Agent-Id: \(credential.agentId)",
            "X-Application-Sid: \(credential.applicationSid)",
        ]
        answerTimer?.cancel()
        answerTimer = clock.after(DialRules.answerDeadline) { [weak self] in
            guard let self = self, seq == self.dialSeq, self.phase == .dialing else { return }
            self.dialFailed(cause: "no_answer", code: nil)
        }
        trace("dial \(dials): INVITE after \(ms(since: nil)) ms")
        ua.invite(target: target, headers: headers, sdp: offer)
    }

    /// The voice bar's dialFailed: one more dial on a fresh connection for the network's failures, else the WebSocket.
    private func dialFailed(cause: String, code: Int?) {
        guard phase == .dialing else { return }
        heardTimer?.cancel()
        answerTimer?.cancel()
        answerClock?.cancel()
        answerClock = nil
        let why = Self.describe(cause: cause, code: code)
        switch DialRules.verdict(cause: cause, code: code, dialsSoFar: dials) {
        case .ignore:
            return
        case .redial:
            trace("dial: \(why) — dialling once more on a fresh connection")
            mark("redial")
            healing = ("redial", clock.now)
            dialSeq += 1
            phase = .ready
            // This dial's gathering says UDP does not get through here: the next one uses the relays over TCP and TLS alone.
            if let media = media, let credential = credential, !relayOnlyByUs,
               RtcResilience.udpLooksBlocked(media.gathered, servers: credential.iceServers),
               !RtcResilience.tcpTlsRelays(credential.iceServers).isEmpty {
                relayOnlyNextDial = true
            }
            // The link's own failures earn the third dial — a second fresh connection.
            freshConnection(after: why, fallback: Self.reason(cause: cause), allowance: DialRules.isLinkFailure(cause: cause, code: code) ? 2 : 1)
        case .fallback:
            giveUp(Self.reason(cause: cause), why)
        }
    }

    /// A new SIP socket and registration for the same call — on the same credential while it has life, else a new one.
    private func freshConnection(after why: String, fallback reason: GraineRtcFallback, allowance: Int = 1) {
        guard freshConnections < allowance, let credential = credential else {
            return giveUp(reason, why)
        }
        freshConnections += 1
        let old = ua
        ua = nil
        uaGeneration += 1
        // A dial given up on is CANCELled — an answer crossing the CANCEL is ACKed and BYEd — on its own socket, which
        // stays until that dial has ended (SipUserAgent.shutDown): a leg left up on the server runs a second agent.
        old?.hangUp()
        old?.shutDown(grace: 0.5)
        redialing = true
        if relayOnlyNextDial { remakeOfferOnRelays() }
        let connect = { [weak self] in
            guard let self = self, self.phase != .ended, self.redialing else { return }
            if credential.remaining(at: self.parts.now()) < DialRules.credentialMinRemaining {
                self.mint()
            } else {
                self.connectSip(credential)
            }
        }
        // Never into no network: a dial that failed because the phone lost its network would fail again at once.
        if parts.network.online { return connect() }
        trace("dial: no network — waiting for it before dialling again")
        waitForNetwork(RtcResilience.redialOfflineWait) { [weak self] back in
            guard let self = self, self.phase != .ended, self.redialing else { return }
            if back {
                self.trace("dial: the network is back")
                connect()
            } else {
                self.giveUp(reason, "\(why); the network did not come back")
            }
        }
    }

    /**
     * THE NEXT DIAL ON THE RELAYS OVER TCP AND TLS ALONE: the peer is told to
     * gather only through them, and a new offer (new ICE credentials) is made
     * before the INVITE goes — the dial waits for it (`offerStale`).
     */
    private func remakeOfferOnRelays() {
        relayOnlyNextDial = false
        guard let media = media, let credential = credential else { return }
        let relays = RtcResilience.tcpTlsRelays(credential.iceServers)
        guard !relays.isEmpty, media.useServers(relays, relayOnly: true) else { return }
        relayOnlyByUs = true
        offerStale = true
        media.gatherPace = pace()
        trace("ice: UDP looked blocked on the last dial — the next one gathers the relays over TCP and TLS only")
        media.reoffer(iceRestart: true) { [weak self] result in
            self?.clock.run {
                guard let self = self, self.offerStale else { return }
                self.offerStale = false
                if case .success(let sdp) = result { self.offer = sdp } else { self.trace("ice: the relay-only offer could not be made — dialling with the one before") }
                self.dialIfReady()
            }
        }
    }

    /// Wait for the network, at most `seconds` — and never past the end (`release` wakes it with false).
    private func waitForNetwork(_ seconds: Double, _ done: @escaping (Bool) -> Void) {
        wakeNetworkWaiter(false)
        var settled = false
        let finish: (Bool) -> Void = { [weak self] back in
            guard !settled else { return }
            settled = true
            self?.networkWaitTimer?.cancel()
            self?.networkWaitTimer = nil
            done(back)
        }
        networkWaiter = finish
        networkWaitTimer = clock.after(seconds) { [weak self] in
            guard let self = self else { return }
            self.networkWaiter = nil
            finish(false)
        }
    }

    private func wakeNetworkWaiter(_ back: Bool) {
        let waiter = networkWaiter
        networkWaiter = nil
        waiter?(back)
    }

    /**
     * The network changed: the last network's word on UDP is worthless, the
     * recovery hears it (nothing restarted into no network; a new network is
     * worth a new gathering), and a redial waiting for it goes.
     */
    private func networkChanged(_ online: Bool) {
        guard phase != .ended else { return }
        trace("network: \(online ? "available" : "gone")")
        media?.forgetGathered()
        relayOnlyNextDial = false
        recovery?.networkChanged(online: online)
        if online { wakeNetworkWaiter(true) }
    }

    /// The link's pace (RtcPace): its registration and its media round trip; 1 when nothing was measured.
    private func pace() -> Double {
        RtcPace.of(registerSeconds: registerSeconds, roundTripSeconds: mediaRoundTrip)
    }

    private func budgetSpent() {
        guard phase < .live else { return }
        // A slow link's own pace: the attempt's budget grows with it.
        if let armed = budgetArmedAt {
            let left = request.budgetSeconds * RtcPace.clamp(pace()) - (clock.now - armed)
            if left > 1e-6 {
                budgetTimer = clock.after(left) { [weak self] in self?.budgetSpent() }
                return
            }
        }
        // Answered, and the recovery still working on the media path (a restart out, its window, a setup still moving):
        // the recovery decides — bounded at 30 s after the answer.
        if phase == .answered, recovery?.holdsTheSetup == true, let answered = answeredAt, clock.now < answered + 30 - 1e-6 {
            budgetTimer = clock.after(answered + 30 - clock.now) { [weak self] in self?.budgetSpent() }
            return
        }
        let reason: GraineRtcFallback
        switch phase {
        case .preparing: reason = credential == nil ? .mintFailed : (registered ? .error : .registerFailed)
        case .dialing: reason = heard ? .noAnswer : .noResponse
        case .answered: reason = .iceTimeout
        default: reason = .error
        }
        giveUp(reason, "WebRTC did not connect within \(Int(request.budgetSeconds)) s", media: phase == .answered ? "ice_timeout" : nil)
    }

    // MARK: - Media

    private func iceChanged(_ state: RtcIceState) {
        guard phase != .ended else { return }
        iceState = state
        if phase == .answered {
            switch state {
            case .connected, .completed:
                goLive()
            case .failed:
                // A restart inside the call before the WebSocket (RtcMediaRecovery acts on it at once).
                if let recovery = recovery {
                    recovery.pathLost(failed: true)
                } else {
                    giveUp(.iceTimeout, "the media path failed before it connected", media: "ice_failed")
                }
            default:
                break
            }
            return
        }
        guard phase == .live else { return }
        switch state {
        case .connected, .completed:
            // Back: the recovery says the reconnect is over, and on the record if a restart brought it back.
            recovery?.pathUp()
        case .disconnected, .failed:
            // Only here, with the media up before: a path that never connected is a fallback, never a reconnect.
            recovery?.pathLost(failed: state == .failed)
        default:
            break
        }
    }

    /// Reconnecting, said once each way.
    private func setReconnecting(_ value: Bool) {
        guard reconnecting != value else { return }
        reconnecting = value
        trace(value ? "media: reconnecting" : "media: reconnected")
        emit(.reconnecting(value))
    }

    private func goLive() {
        guard phase == .answered else { return }
        phase = .live
        budgetTimer?.cancel()
        // The path is up: a restart that brought it up is on the record.
        recovery?.pathUp()
        mark("connected")
        trace("connected: media \(ms(since: "answered")) ms after the answer, \(ms(since: nil)) ms after the start")
        emit(.connected)
        sendConnectRow()
        if let heal = healing, heal.what == "redial" {
            healing = nil
            sendRecoveryRow("redial", since: heal.since)
        }
        pollLevel()
        routeUnwatch = parts.audio.watchRoute { [weak self] event in self?.clock.run { self?.routeEvent(event) } }
    }

    /// "Agent speaking", from what the receiver plays: five readings a second.
    private func pollLevel() {
        levelTimer?.cancel()
        levelTimer = clock.after(Self.levelSeconds) { [weak self] in
            guard let self = self, self.phase == .live, let media = self.media else { return }
            media.inboundAudio { stats in
                self.clock.run {
                    guard self.phase == .live else { return }
                    if let stats = stats { self.heardLevel(stats) }
                    self.pollLevel()
                }
            }
        }
    }

    private func heardLevel(_ stats: RtcInboundAudio) {
        watchPlayout(stats)
        // Nothing received yet (only the playout count is known): no level, no quality.
        guard stats.inbound, phase == .live else { return }
        // The link's own round trip, for the pace the next deadlines scale with.
        if let rtt = stats.roundTrip, rtt.isFinite, rtt > 0 { mediaRoundTrip = rtt }
        if stats.packetsReceived > 0, marks["first_packet"] == nil { mark("first_packet") }
        quality.add(stats)
        // The agent's voice as the receiver plays it out, for the call screen's visualiser (smoothed by the SDK).
        emit(.level(stats.audioLevel.isFinite ? max(0, min(1, stats.audioLevel)) : 0))
        reportAudio()
        if stats.audioLevel >= Self.speakingLevel {
            if marks["first_voice"] == nil {
                mark("first_voice")
                trace("first agent audio \(ms(since: "answered")) ms after the answer (\(stats.codec ?? "codec unknown"))")
                sendVoiceRow(stats)
            }
            quietSince = nil
            if !speaking {
                speaking = true
                emit(.speaking(true))
            }
        } else if speaking, stats.audioLevel < Self.quietLevel {
            let since = quietSince ?? clock.now
            quietSince = since
            if clock.now - since >= Self.quietSeconds {
                speaking = false
                quietSince = nil
                emit(.speaking(false))
            }
        }
    }

    /**
     * THE PLAYOUT WATCH — whether the agent's audio reaches the speaker, read
     * from what the phone's playout counts (`samplesReceived`, `playoutSamples`:
     * samples taken by the speaker, whatever they hold), never from the
     * agent's level: a quiet agent is not a silent speaker.
     *
     *   ready     the audio activated (by CallKit, or started directly) and
     *             the counts moving steadily for `readyStableSeconds`: the
     *             control channel hears GraineRtcSignal.audioReady — the
     *             greeting waits for it — and an `audio` row says so. Once;
     *             and once more each time the audio comes back after it was
     *             lost (taken back by the system, or stalled and restarted),
     *             the row giving why: the server then knows how much of what
     *             it sent may not have been heard
     *   stalled   2 s of readings with packets arriving and not a sample
     *             played — or with libwebrtc's own count of what the speaker
     *             took standing still, which needs no packet (the greeting is
     *             held for this very signal): the phone's audio started again
     *             (RtcAudioControl.restart), once per stall — what the
     *             session reported is the reason
     *   unheard   3 s after that restart, 2 s of packets still unplayed — or a
     *             restart that would not start: `playoutFailed`, and the core
     *             ends the call (cause `audio_watch`). Only audio that arrived
     *             and was not played ends a call; a count standing still alone
     *             never does
     *
     * Nothing is judged where nothing is counted (a library that reports no
     * samples), nor, without its own count, while nothing arrives.
     */
    private func watchPlayout(_ stats: RtcInboundAudio) {
        guard phase == .live, !playoutFailed else { return }
        let now = clock.now
        let last = lastPlayout
        lastPlayout = (stats.samplesReceived, stats.playoutSamples, stats.packetsReceived, now)
        guard let before = last else { return }
        func grew(_ now: Int?, _ then: Int?) -> Bool {
            guard let now = now, let then = then else { return false }
            return now > then
        }
        if grew(stats.samplesReceived, before.samples) || grew(stats.playoutSamples, before.playout) {
            unplayedFor = 0
            stillFor = 0
            playoutRestartedAt = nil
            guard audioOn else {
                playingSince = nil
                return
            }
            // Playing since the last reading — never since before the audio came on.
            let since = playingSince ?? max(before.at, audioOnSince ?? before.at)
            playingSince = since
            guard !audioReady || readyAgainBecause != nil, now - since >= Self.readyStableSeconds - 1e-9 else { return }
            let again = readyAgainBecause
            audioReady = true
            readyAgainBecause = nil
            control?.send(GraineRtcSignal.audioReady, kind: nil)
            sendAudioRow("ready", reason: again)
            trace(again.map { "audio: playing again after it was lost (\($0)) — the channel told it is ready again" }
                  ?? "audio: playing steadily (\(audioVia)) — the channel told it is ready")
            return
        }
        // The counts stood still: a steady stretch starts over.
        playingSince = nil
        // While the system holds the audio, or the route settles, nothing is judged: the readings only keep the baseline.
        if interrupted { return }
        if let until = settleUntil {
            guard now >= until - 1e-9 else { return }
            settleUntil = nil
        }
        let elapsed = now - before.at
        // Audio arrived, and the receiver counted none of it played.
        if stats.inbound, stats.samplesReceived != nil, before.samples != nil, stats.packetsReceived > before.packets { unplayedFor += elapsed }
        // libwebrtc's own count of what the speaker took, standing still.
        if stats.playoutSamples != nil, before.playout != nil { stillFor += elapsed }
        let stall = Self.playoutStallSeconds - 1e-9
        if let restarted = playoutRestartedAt {
            if unplayedFor >= stall, now - restarted >= Self.playoutFailAfter - 1e-9 { playoutUnheard("no_playout") }
            return
        }
        guard unplayedFor >= stall || stillFor >= stall else { return }
        let cause = parts.audio.stallCause() ?? "no_playout"
        playoutRestartedAt = now
        trace("audio: nothing played for \(Int((max(unplayedFor, stillFor) * 1000).rounded())) ms (\(cause)) — starting it again")
        unplayedFor = 0
        stillFor = 0
        let restarted = parts.audio.restart()
        sendAudioRow("playout_restarted", reason: cause)
        if restarted {
            // Started afresh: a steady stretch counts from now — and, said ready already, it is said again once it plays.
            audioOn = true
            audioOnSince = now
            playingSince = nil
            if audioReady { readyAgainBecause = cause }
        } else {
            playoutUnheard(cause)
        }
    }

    /**
     * THE ROUTE MOVED, or the system interrupted the audio. iOS remakes the
     * audio unit for the new output — a Bluetooth headset's or a car kit's
     * hands-free link can take seconds — and nothing plays meanwhile while
     * packets keep arriving, which the playout watch would read as a stall.
     * Once this call's audio has been heard, the watch stands aside: its
     * counts begin afresh (the next reading is the baseline), nothing is
     * judged for `routeSettleSeconds`, and a restart already made is judged
     * from the end of the settling. Before the audio was ever heard there is
     * no healthy audio to protect, and the rescue of a call that never played
     * is not delayed. An interruption pauses the watch either way, until it
     * ends (then it settles, as for a move). Each move is said in an `audio`
     * row: the output's kind only.
     */
    private func routeEvent(_ event: RtcAudioRouteEvent) {
        guard phase == .live, !playoutFailed else { return }
        switch event {
        case .changed(let kind):
            if kind != lastRoute, routeRows < Self.routeRowsMax {
                routeRows += 1
                lastRoute = kind
                sendAudioRow("route_changed", reason: nil, route: kind)
            }
            guard audioReady else { return }
            standAside()
            trace("audio: the route moved (\(kind ?? "unknown")) — nothing judged for \(Int(Self.routeSettleSeconds)) s")
        case .interrupted:
            // Whether or not anything was heard yet: a restart while the system holds the audio could only fail.
            interrupted = true
            settleUntil = nil
            freshCounts()
            trace("audio: the system interrupted it — nothing judged until it ends")
        case .resumed(let kind):
            interrupted = false
            freshCounts()
            guard audioReady else { return }
            standAside()
            trace("audio: the interruption ended (\(kind ?? "unknown")) — nothing judged for \(Int(Self.routeSettleSeconds)) s")
        }
    }

    /// The watch's counts begin afresh: the next reading is the baseline.
    private func freshCounts() {
        unplayedFor = 0
        stillFor = 0
        lastPlayout = nil
        playingSince = nil
    }

    /// Nothing judged for `routeSettleSeconds`; a restart already made is judged from the end of it.
    private func standAside() {
        freshCounts()
        let until = clock.now + Self.routeSettleSeconds
        settleUntil = max(settleUntil ?? until, until)
        if let restarted = playoutRestartedAt { playoutRestartedAt = max(restarted, until) }
    }

    /// The call cannot be heard: said once, in a row and to the SDK, which ends it.
    private func playoutUnheard(_ reason: String) {
        guard !playoutFailed else { return }
        playoutFailed = true
        sendAudioRow("failed", reason: reason)
        trace("audio: nothing played after the restart (\(reason)) — the call cannot be heard")
        emit(.playoutFailed("audio arrived and nothing played (\(reason))"))
    }

    // MARK: - Endings

    /**
     * Before any media: release everything and hand the call to the WebSocket.
     * `media`: answered, and no audio path — the call's media row says why, on
     * its own channel before it closes (best effort).
     */
    private func giveUp(_ reason: GraineRtcFallback, _ detail: String, media: String? = nil) {
        guard phase != .ended, phase != .live else { return }
        trace("giving up (\(reason.rawValue)): \(detail)")
        if let why = media, phase == .answered { sendRow("media", ["reason": why, "transport": "rtc"]) }
        release(sendBye: true)
        emit(.unreachable(reason, detail: detail))
        notePrepared(.lost)
    }

    /// After media: the call is over.
    private func end(_ ending: GraineRtcEnding) {
        guard phase == .live else { return }
        if case .dropped(let why) = ending { trace("dropped: \(why)") }
        // Their BYE (or the path lost): the quality row at once, while the channel may still be open, then who ended it.
        sendQualityRow()
        sendEndedRow(ending == .remote ? "remote_bye" : "media_drop")
        release(sendBye: ending != .remote)
        if speaking {
            speaking = false
            emit(.speaking(false))
        }
        // A call that ends while reconnecting is reconnecting no more.
        setReconnecting(false)
        emit(.ended(ending))
    }

    private func release(sendBye: Bool) {
        phase = .ended
        routeUnwatch?()
        routeUnwatch = nil
        for timer in [budgetTimer, heardTimer, answerTimer, answerClock, registerTimer, levelTimer, networkWaitTimer] { timer?.cancel() }
        // No restart and no redial after the end: the recovery goes, and a redial waiting for the network is told no.
        let kept = recovery
        recovery = nil
        kept?.dispose()
        wakeNetworkWaiter(false)
        networkUnwatch?()
        networkUnwatch = nil
        if sendBye { ua?.hangUp() }
        ua?.shutDown()
        ua = nil
        uaGeneration += 1
        control?.close()
        media?.close()
        media = nil
        if audioTaken {
            audioTaken = false
            parts.audio.callEnds()
        }
    }

    // MARK: - Analytics rows

    /**
     * THE CALL'S ANALYTICS ROWS (GraineCallTelemetry, contract v1), on its own
     * control channel: it keeps them until it joins and drops them if it never
     * does, so a row never delays the call or its hang-up. Each also goes up
     * to the SDK as it is made (GraineRtcEvent.row): the call's connection
     * report, live. Durations in whole milliseconds, measured on the call's
     * clock; never an id or an identity.
     */
    private func sendRow(_ name: String, _ data: [String: Any?]) {
        guard let frame = GraineCallTelemetry.frame(name, data) else { return }
        sendRow(frame)
    }

    /// A row on the channel — and up to the SDK, which reads the call's connection report from its rows.
    private func sendRow(_ frame: String) {
        control?.send(frame, kind: nil)
        emit(.row(frame))
    }

    private func span(_ from: Double?, _ to: Double?) -> Int? {
        GraineCallTelemetry.milliseconds(from: from, to: to)
    }

    /**
     * HOW THE CALL ENDED, once, for a call that was dialled — as Android's
     * leg says it: who or what ended it, how long the call had its audio
     * (from media, once it had it) and whether the agent's voice was heard;
     * on the control channel before the BYE, or at the far side's while the
     * channel may still be open, and up to the SDK.
     */
    private func sendEndedRow(_ cause: String) {
        guard begun, !endedSent else { return }
        endedSent = true
        guard let frame = GraineCallTelemetry.endedFrame(
            cause: cause,
            transport: "rtc",
            afterMs: phase == .live ? span(marks["connected"], clock.now) : nil,
            voiceHeard: marks["first_voice"] != nil
        ) else { return }
        sendRow(frame)
    }

    /**
     * At media, once: the transport row its dialler wrote, then the connect
     * row. total = setup + dial: the tap (`begin`) to the last INVITE, that
     * INVITE to the answer. Prepared means set up and registered before the
     * tap; then mint, gather and register are the preparation's own times,
     * and its age at the tap is said. Cold, they are inside setup.
     */
    private func sendConnectRow() {
        if let row = transportRow { sendRow(row) }
        let prepared = preparedAhead && readyAtTap
        let tap = marks["begin"] ?? startedAt
        let answered = marks["answered"] ?? clock.now
        let invite = lastInviteAt ?? marks["invite"] ?? answered
        let setup = span(tap, invite), dial = span(invite, answered)
        var total = span(tap, answered)
        if let setup = setup, let dial = dial { total = setup + dial }
        sendRow("connect", [
            "mode": prepared ? "prepared" : "cold",
            "warm": prepared,
            "total_ms": total,
            "setup_ms": setup,
            "dial_ms": dial,
            "mint_ms": span(marks["mint_sent"], marks["minted"]),
            "mint_route": marks["minted"] == nil ? nil : (mintedDirect ? "direct" : "web"),
            "gather_ms": span(marks["minted"], marks["offer"]),
            "register_ms": firstRegisterMs,
            "redials": max(0, dials - 1),
            "prepared_age_s": prepared ? max(0, tap - startedAt) : nil,
            "ice_ms": span(answered, marks["connected"]),
        ])
    }

    /// When the agent's voice is first heard, once: from the tap, from the answer, the first audio of any kind, the codec and our side of the path.
    private func sendVoiceRow(_ stats: RtcInboundAudio) {
        let voice = marks["first_voice"] ?? clock.now
        sendRow("voice", [
            "tap_to_voice_ms": span(marks["begin"] ?? startedAt, voice),
            "answer_to_voice_ms": span(marks["answered"], voice),
            "first_audio_ms": span(marks["answered"], marks["first_packet"]),
            "codec": stats.codecName,
            "candidate": stats.candidate,
        ])
    }

    /// Each time the connection heals: what healed it, and how long the trouble lasted.
    private func sendRecoveryRow(_ what: String, since: Double) {
        sendRow("recovery", ["what": what, "after_ms": span(since, clock.now)])
    }

    /// The phone's audio when it matters (GraineCallTelemetry.audioFrame): ready once, and each exception — from the tap.
    private func sendAudioRow(_ event: String, reason: String?, route: String? = nil) {
        let frame = GraineCallTelemetry.audioFrame(event: event, transport: "rtc", via: audioVia, reason: reason,
                                                   afterMs: span(marks["begin"] ?? startedAt, clock.now), route: route)
        if let frame = frame { sendRow(frame) }
    }

    /**
     * The audio as received so far — the running figures the quality row will
     * carry — up to the SDK about once a second while the call is live, for
     * its connection report. Never on the channel: the quality row says it
     * there, once, at the end.
     */
    private func reportAudio() {
        if let last = audioReportedAt, clock.now - last < Self.audioReportSeconds { return }
        audioReportedAt = clock.now
        emit(.audio(lossPct: quality.lossPercent, jitterAvgMs: quality.jitterAverageMs, jitterMaxMs: quality.jitterMaxMs, rttAvgMs: quality.roundTripAverageMs))
    }

    /// At the end of a call that had media, once, best effort: how long, and how the audio fared.
    private func sendQualityRow() {
        guard !qualitySent, let connected = marks["connected"] else { return }
        qualitySent = true
        sendRow("quality", [
            "duration_s": max(0, clock.now - connected),
            "loss_pct": quality.lossPercent,
            "jitter_avg_ms": quality.jitterAverageMs,
            "jitter_max_ms": quality.jitterMaxMs,
            "rtt_avg_ms": quality.roundTripAverageMs,
        ])
    }

    // MARK: - Events and the log

    private func emit(_ event: GraineRtcEvent) {
        sinkLock.lock()
        if silenced {
            sinkLock.unlock()
            return
        }
        let target = sink
        if target == nil { held.append(event) }
        sinkLock.unlock()
        target?(event)
    }

    private func flush() {
        sinkLock.lock()
        guard let target = sink, !held.isEmpty, !silenced else {
            sinkLock.unlock()
            return
        }
        let waiting = held
        held = []
        sinkLock.unlock()
        for event in waiting { target(event) }
    }

    private func silence() {
        sinkLock.lock()
        silenced = true
        held = []
        preparedSink = nil
        sinkLock.unlock()
    }

    /// Tell whoever prepared the call ahead of its dial (nobody, once it is dialled or hung up).
    private func notePrepared(_ state: GraineRtcPreparedState) {
        sinkLock.lock()
        let target = silenced ? nil : preparedSink
        sinkLock.unlock()
        target?(state)
    }

    private func trace(_ line: String) {
        guard request.debug else { return }
        emit(.log("rtc: " + line))
    }

    private func mark(_ name: String) {
        if marks[name] == nil { marks[name] = clock.now }
    }

    private func ms(since name: String?) -> Int {
        let from = name.flatMap { marks[$0] } ?? startedAt
        return Int(((clock.now - from) * 1000).rounded())
    }

    private func describe(_ failure: SipUserAgent.Failure) -> String {
        Self.describe(cause: failure.cause, code: failure.code)
    }

    /// The voice bar's describeDialFailure.
    static func describe(cause: String, code: Int?) -> String {
        if cause == "no_response" { return "no reply to the INVITE" }
        if cause == "no_answer" { return "not answered" }
        if code == 491 { return "491 Request Pending" }
        return code.map { "\(cause) \($0)" } ?? cause
    }

    /// The fallback's reason, in the voice bar's words.
    static func reason(cause: String) -> GraineRtcFallback {
        switch cause {
        case "no_response": return .noResponse
        case "no_answer": return .noAnswer
        default: return .error
        }
    }
}

// MARK: - The media path, kept (RtcMediaRecovery's host)

extension RtcCallEngine: RtcRecoveryHost {
    func recoveryPace() -> Double { pace() }

    func recoveryOnline() -> Bool { parts.network.online }

    /// The call is answered, its socket is open (not reconnecting), and no offer of ours or theirs is out.
    func recoveryCanReoffer() -> Bool {
        guard phase == .answered || phase == .live, media != nil, let ua = ua else { return false }
        return ua.isOpen && sipLostAt == nil && !restartOut && !ua.reinviteInFlight
    }

    /**
     * ONE ICE RESTART, inside the answered call: the peer offers again with new
     * ICE credentials (gathered by the same rule, on the relays over TCP and TLS
     * alone when `relayOnly`, on every server again otherwise — a relay-only
     * setting this engine made never outlives the restart after it), sent as a
     * re-INVITE in the dialog, its answer applied. Never a new call: no second
     * conversation, no greeting, the audio-ready word already said stays said.
     */
    func recoveryRestart(_ n: Int, relayOnly: Bool, _ on: RtcRestartHandlers) -> Bool {
        guard recoveryCanReoffer(), let media = media, let ua = ua, let credential = credential else { return false }
        let seq = dialSeq
        if relayOnly {
            let relays = RtcResilience.tcpTlsRelays(credential.iceServers)
            if !relays.isEmpty, media.useServers(relays, relayOnly: true) { relayOnlyByUs = true }
        } else if relayOnlyByUs {
            if media.useServers(credential.iceServers, relayOnly: false) { relayOnlyByUs = false }
        }
        media.gatherPace = pace()
        restartOut = true
        let still: () -> Bool = { [weak self] in
            guard let self = self else { return false }
            return seq == self.dialSeq && (self.phase == .answered || self.phase == .live)
        }
        media.reoffer(iceRestart: true) { [weak self] result in
            self?.clock.run {
                guard let self = self else { return }
                guard still() else { self.restartOut = false; return }
                switch result {
                case .failure(let error):
                    self.restartOut = false
                    on.refused("its offer could not be made (\(error))")
                case .success(let sdp):
                    on.offer(RtcResilience.candidateCount(sdp))
                    guard still() else { self.restartOut = false; return }
                    ua.reinvite(sdp: sdp) { [weak self] answer in
                        self?.clock.run {
                            guard let self = self else { return }
                            self.restartOut = false
                            guard still() else { return }
                            switch answer {
                            case .failure(let failure):
                                on.refused(self.describe(failure))
                            case .success(let answerSdp):
                                media.applyAnswer(answerSdp) { [weak self] error in
                                    guard let self = self, still() else { return }
                                    if let error = error { on.refused("its answer was refused (\(error))") } else { on.answered() }
                                }
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    func recoveryStats(_ done: @escaping (RtcIceReading?) -> Void) {
        guard let media = media else { return done(nil) }
        media.iceStats(done)
    }

    func recoveryUdpBlocked() -> Bool {
        guard let media = media, let credential = credential else { return false }
        return RtcResilience.udpLooksBlocked(media.gathered, servers: credential.iceServers) && !RtcResilience.tcpTlsRelays(credential.iceServers).isEmpty
    }

    func recoveryFailed(_ failure: RtcMediaFailure) {
        switch phase {
        case .answered:
            // Before any audio: the WebSocket carries the call, as before.
            if case .iceFailed = failure {
                giveUp(.iceTimeout, failure.detail, media: "ice_failed")
            } else {
                giveUp(.iceTimeout, failure.detail, media: "ice_timeout")
            }
        case .live:
            end(.dropped(failure.detail))
        default:
            break
        }
    }

    func recoveryReconnecting(_ active: Bool) {
        guard phase == .live || !active else { return }
        setReconnecting(active)
    }

    func recoveryRecovered(restarts: Int, seconds: Double) {
        trace("media: back after \(Int((seconds * 1000).rounded())) ms — \(restarts) ICE restart\(restarts > 1 ? "s" : "")")
        sendRecoveryRow("ice_restart", since: clock.now - seconds)
    }

    func recoveryLog(_ line: String) { trace(line) }
}

/// The receiver's numbers across a call, from the five-a-second readings: for its quality row.
struct RtcQualitySamples {
    private var jitterSum = 0.0
    private var jitterMax = 0.0
    private var jitterCount = 0
    private var roundTripSum = 0.0
    private var roundTripCount = 0
    private var lost = 0
    private var received = 0

    mutating func add(_ stats: RtcInboundAudio) {
        // The counters are the call's running totals: the latest reading is the whole call's.
        lost = max(lost, stats.packetsLost)
        received = max(received, stats.packetsReceived)
        if stats.packetsReceived > 0, stats.jitter.isFinite, stats.jitter >= 0 {
            jitterSum += stats.jitter
            jitterMax = max(jitterMax, stats.jitter)
            jitterCount += 1
        }
        if let rtt = stats.roundTrip, rtt.isFinite, rtt >= 0 {
            roundTripSum += rtt
            roundTripCount += 1
        }
    }

    /// Lost of all sent, in percent; nil before any packet.
    var lossPercent: Double? {
        let all = lost + received
        return all > 0 ? Double(lost) / Double(all) * 100 : nil
    }

    var jitterAverageMs: Double? { jitterCount > 0 ? jitterSum / Double(jitterCount) * 1000 : nil }
    var jitterMaxMs: Double? { jitterCount > 0 ? jitterMax * 1000 : nil }
    var roundTripAverageMs: Double? { roundTripCount > 0 ? roundTripSum / Double(roundTripCount) * 1000 : nil }
}
