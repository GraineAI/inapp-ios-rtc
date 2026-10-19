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
 *             exists) and the attempt's budget starts: 12 s to media, or the
 *             call is the WebSocket's
 *   audio     CallKit activated the session (or, failing that, it was started
 *             directly): only now does the INVITE leave, so the greeting is
 *             never played into a session that is not running
 *   dial      INVITE with X-Graine-Session-Id, X-Graine-Agent-Id and
 *             X-Application-Sid; no reply within the link's own pace, no
 *             answer within 15 s, or no media 8 s after the answer, and the
 *             dial has failed — a network-ish failure gets one more dial on a
 *             fresh connection, anything else goes to the WebSocket
 *   live      the media watched: a path lost for 3 s is restarted once (a
 *             re-INVITE with new ICE credentials); not back within 10 s, or
 *             lost for 8 s with no restart possible, and the call has dropped
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
                direct: RtcDirectMint.shared
            )
        }
    }

    /// The agent is audible above this level, and quiet once below `quietLevel` for `quietSeconds`.
    static let speakingLevel = 0.02
    static let quietLevel = 0.01
    static let quietSeconds = 0.5
    /// Five readings a second.
    static let levelSeconds = 0.2
    /// A media path lost this long is restarted, once.
    static let restartAfter = 3.0
    /// Lost this long with no restart possible: dropped (the voice bar's rule).
    static let dropAfter = 8.0
    /// Lost this long, restart or not: dropped.
    static let restartDropAfter = 10.0

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
    private var restartedAt: Double?
    private var qualitySent = false
    private var quality = RtcQualitySamples()
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
    private var heard = false
    private var heardArmed = false
    private var redialing = false
    private var freshConnections = 0
    private var budgetTimer: RtcTimer?
    private var heardTimer: RtcTimer?
    private var answerTimer: RtcTimer?
    private var iceTimer: RtcTimer?
    private var iceState = RtcIceState.new
    private var dropBegan: Double?
    private var dropTimers: [RtcTimer] = []
    private var restartTried = false
    private var levelTimer: RtcTimer?
    private var speaking = false
    private var quietSince: Double?
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
            budgetTimer = clock.after(request.budgetSeconds) { [weak self] in self?.budgetSpent() }
            dialIfReady()
        }
    }

    func audioActivated() {
        clock.run { [self] in
            guard phase != .ended else { return }
            parts.audio.activated()
            audioOn = true
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
                audioOn = true
                mark("audio")
                trace("audio: started without CallKit")
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
        }
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

    func hangUp() {
        clock.run { [self] in
            guard phase != .ended else { return }
            // The call's quality row goes before the BYE, on the channel still open; best effort, never waited for.
            if phase == .live { sendQualityRow() }
            // Nothing is reported after a hang-up, not even to the log: the caller has moved on.
            silence()
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
    private func mint() {
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
        direct.mint(baseUrl: base, body: body) { [weak self] answer in
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

    /// `POST {baseUrl}/api/embed/rtc-session`: every check on the way, and a grant back beside the credential.
    private func mintOnWebRoute(_ url: URL, base: String, body: Data) {
        parts.minting.mint(url, body: body) { [weak self] outcome in
            self?.clock.run {
                guard let self = self else { return }
                if case .credential(let credential) = outcome {
                    if let offer = credential.direct {
                        // The grant beside the credential is this call's own: a redial's mint takes it to the gateway.
                        self.parts.direct?.accept(offer, baseUrl: base, body: body)
                    } else if self.request.rang {
                        // A call that rang, and its answer brought no grant: one asked for on its own, for a later mint of it.
                        self.parts.direct?.warm(baseUrl: base, body: body)
                    }
                }
                self.minted(outcome, at: nil)
            }
        }
    }

    private func minted(_ outcome: RtcMintOutcome, at place: String?) {
        guard phase == .preparing || redialing else { return }
        if case let .refused(_, code?, message) = outcome, GraineRtcRefusal.codes.contains(code) {
            // A gate said no to the call itself: it ends here, in the gate's words — no fallback.
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
            heardTimer = clock.after(DialRules.heardDeadline(registerSeconds: registerSeconds)) { [weak self] in
                guard let self = self, seq == self.dialSeq, self.phase == .dialing, !self.heard else { return }
                self.dialFailed(cause: "no_response", code: nil)
            }

        case .heard(let code):
            guard phase == .dialing else { return }
            if !heard {
                mark("heard")
                // The SBC has it: still only "trying" after DialRules.answerAfterHeard is a stuck dial, cancelled
                // and dialled once more on a fresh connection while the attempt's budget still has room.
                let seq = dialSeq
                answerTimer?.cancel()
                answerTimer = clock.after(DialRules.answerAfterHeard) { [weak self] in
                    guard let self = self, seq == self.dialSeq, self.phase == .dialing else { return }
                    self.dialFailed(cause: "no_answer", code: nil)
                }
            }
            heard = true
            heardTimer?.cancel()
            trace("dial: \(code)")

        case let .answered(sdp, callSid):
            guard phase == .dialing, let media = media else { return }
            heardTimer?.cancel()
            answerTimer?.cancel()
            phase = .answered
            mark("answered")
            trace("answered in \(ms(since: "invite")) ms\(callSid.map { " (call \($0))" } ?? "")")
            // From here the BYE needs this socket: a lost one is reconnected, not abandoned.
            ua?.keepsTransport = true
            iceTimer = clock.after(DialRules.iceConnectDeadline) { [weak self] in
                guard let self = self, self.phase == .answered else { return }
                self.giveUp(.iceTimeout, "the media path did not connect within \(Int(DialRules.iceConnectDeadline)) s of the answer", media: "ice_timeout")
            }
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
        guard phase == .ready, begun, audioOn, !redialing, let offer = offer, let ua = ua, let credential = credential else { return }
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
            freshConnection(after: why, fallback: Self.reason(cause: cause))
        case .fallback:
            giveUp(Self.reason(cause: cause), why)
        }
    }

    /// A new SIP socket and registration for the same call — on the same credential while it has life, else a new one.
    private func freshConnection(after why: String, fallback reason: GraineRtcFallback) {
        guard freshConnections < 1, let credential = credential else {
            return giveUp(reason, why)
        }
        freshConnections += 1
        let old = ua
        ua = nil
        uaGeneration += 1
        old?.hangUp()
        old?.shutDown(grace: 0.5)
        redialing = true
        if credential.remaining(at: parts.now()) < DialRules.credentialMinRemaining {
            mint()
        } else {
            connectSip(credential)
        }
    }

    private func budgetSpent() {
        guard phase < .live else { return }
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
                giveUp(.iceTimeout, "the media path failed before it connected", media: "ice_failed")
            default:
                break
            }
            return
        }
        guard phase == .live else { return }
        switch state {
        case .connected, .completed:
            if let began = dropBegan {
                trace("media: back after \(Int((clock.now - began) * 1000)) ms")
                // Healed by the restart it was given (back on its own, it is no recovery of ours).
                if restartedAt != nil { sendRecoveryRow("ice_restart", since: began) }
            }
            restartedAt = nil
            dropBegan = nil
            for timer in dropTimers { timer.cancel() }
            dropTimers = []
        case .disconnected, .failed:
            mediaLost(failed: state == .failed)
        default:
            break
        }
    }

    private func goLive() {
        guard phase == .answered else { return }
        phase = .live
        iceTimer?.cancel()
        budgetTimer?.cancel()
        mark("connected")
        trace("connected: media \(ms(since: "answered")) ms after the answer, \(ms(since: nil)) ms after the start")
        emit(.connected)
        sendConnectRow()
        if let heal = healing, heal.what == "redial" {
            healing = nil
            sendRecoveryRow("redial", since: heal.since)
        }
        pollLevel()
    }

    /// The path went away: restart it once if it fits, and call it dropped if it does not come back.
    private func mediaLost(failed: Bool) {
        let first = dropBegan == nil
        if first {
            dropBegan = clock.now
            trace("media: \(failed ? "failed" : "disconnected")")
            dropTimers.append(clock.after(Self.restartAfter) { [weak self] in
                guard let self = self, self.phase == .live, self.dropBegan != nil else { return }
                self.restartIce()
            })
            dropTimers.append(clock.after(Self.dropAfter) { [weak self] in
                guard let self = self, self.phase == .live, self.dropBegan != nil, !self.restartTried else { return }
                self.end(.dropped("the media path was lost for more than \(Int(Self.dropAfter)) s"))
            })
            dropTimers.append(clock.after(Self.restartDropAfter) { [weak self] in
                guard let self = self, self.phase == .live, self.dropBegan != nil else { return }
                self.end(.dropped("the media path did not come back within \(Int(Self.restartDropAfter)) s"))
            })
        }
        if failed { restartIce() }
    }

    /// One re-INVITE with new ICE credentials; if it cannot be made or is refused, the call has dropped.
    private func restartIce() {
        guard !restartTried, phase == .live, let media = media, let ua = ua else { return }
        restartTried = true
        restartedAt = clock.now
        trace("media: restarting ICE")
        media.reoffer(iceRestart: true) { [weak self] result in
            guard let self = self, self.phase == .live else { return }
            switch result {
            case .failure(let error):
                self.end(.dropped("the media path was lost and could not be restarted (\(error))"))
            case .success(let sdp):
                ua.reinvite(sdp: sdp) { [weak self] answer in
                    self?.clock.run {
                        guard let self = self, self.phase == .live else { return }
                        switch answer {
                        case .failure(let failure):
                            self.end(.dropped("the media path was lost and its restart was refused (\(self.describe(failure)))"))
                        case .success(let answerSdp):
                            media.applyAnswer(answerSdp) { [weak self] error in
                                guard let self = self, self.phase == .live, let error = error else { return }
                                self.end(.dropped("the restarted media path was refused (\(error))"))
                            }
                        }
                    }
                }
            }
        }
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
        if stats.packetsReceived > 0, marks["first_packet"] == nil { mark("first_packet") }
        quality.add(stats)
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
        // Their BYE (or the path lost): the quality row at once, while the channel may still be open.
        sendQualityRow()
        release(sendBye: ending != .remote)
        if speaking {
            speaking = false
            emit(.speaking(false))
        }
        emit(.ended(ending))
    }

    private func release(sendBye: Bool) {
        phase = .ended
        for timer in [budgetTimer, heardTimer, answerTimer, iceTimer, registerTimer, levelTimer] { timer?.cancel() }
        for timer in dropTimers { timer.cancel() }
        dropTimers = []
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
     * does, so a row never delays the call or its hang-up. Durations in whole
     * milliseconds, measured on the call's clock; never an id or an identity.
     */
    private func sendRow(_ name: String, _ data: [String: Any?]) {
        guard let frame = GraineCallTelemetry.frame(name, data) else { return }
        control?.send(frame, kind: nil)
    }

    private func span(_ from: Double?, _ to: Double?) -> Int? {
        GraineCallTelemetry.milliseconds(from: from, to: to)
    }

    /**
     * At media, once: the transport row its dialler wrote, then the connect
     * row. total = setup + dial: the tap (`begin`) to the last INVITE, that
     * INVITE to the answer. Prepared means set up and registered before the
     * tap; then mint, gather and register are the preparation's own times,
     * and its age at the tap is said. Cold, they are inside setup.
     */
    private func sendConnectRow() {
        if let row = transportRow { control?.send(row, kind: nil) }
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
