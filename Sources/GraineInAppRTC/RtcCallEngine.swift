@_spi(GraineRTC) import GraineInApp
import Foundation

/*
 * ONE CALL ON WEBRTC — exactly the voice bar's sequence, in the app's own
 * process, under CallKit.
 *
 *   prepare   a session id; the call session minted (with the same identity
 *             and variables the call's ticket carries); then, side by side,
 *             the peer gathering its candidates and the SIP socket registering
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
                audio: audio
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

    // Everything below is touched on the clock only.
    private var phase = Phase.idle
    private var control: RtcControlChannel?
    private var credential: RtcCredential?
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

    func prepare() {
        clock.run { [self] in
            guard phase == .idle else { return }
            phase = .preparing
            startedAt = clock.now
            // Nothing touches the microphone until CallKit hands the audio over.
            parts.audio.callBegins()
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
            // Nothing is reported after a hang-up, not even to the log: the caller has moved on.
            silence()
            release(sendBye: true)
        }
    }

    // MARK: - The call session

    private func mint() {
        var base = request.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/embed/rtc-session") else {
            return giveUp(.mintFailed, "the base URL is not a URL")
        }
        mark("mint_sent")
        parts.minting.mint(url, body: request.mintBody(sessionId)) { [weak self] outcome in
            self?.clock.run { self?.minted(outcome) }
        }
    }

    private func minted(_ outcome: RtcMintOutcome) {
        guard phase == .preparing || redialing else { return }
        if case let .refused(_, code?, message) = outcome, GraineRtcRefusal.codes.contains(code) {
            // A gate said no to the call itself: it ends here, in the gate's words — no fallback.
            trace("refused by the call session: \(code)")
            release(sendBye: false)
            emit(.refused(code: code, message: message ?? ""))
            return
        }
        guard case .credential(let credential) = outcome else {
            return giveUp(.mintFailed, outcome.detail)
        }
        mark("minted")
        trace("minted in \(ms(since: "mint_sent")) ms (\(credential.iceServers.count) ICE server(s))")
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

        case .registered(let seconds):
            registered = true
            registerSeconds = seconds
            registerTimer?.cancel()
            mark("registered")
            trace("registered in \(Int(seconds * 1000)) ms")
            redialing = false
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
            switch phase {
            case .preparing, .ready:
                // Before the dial: one fresh connection, as a dead warm socket gets one in the voice bar.
                freshConnection(after: "the SIP socket closed (\(detail))", fallback: .registerFailed)
            case .answered:
                ua?.keepsTransport = true
            default:
                break
            }

        case .inviteSent:
            guard phase == .dialing, !heardArmed else { return }
            heardArmed = true
            mark("invite")
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
                self.giveUp(.iceTimeout, "the media path did not connect within \(Int(DialRules.iceConnectDeadline)) s of the answer")
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
        giveUp(reason, "WebRTC did not connect within \(Int(request.budgetSeconds)) s")
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
                giveUp(.iceTimeout, "the media path failed before it connected")
            default:
                break
            }
            return
        }
        guard phase == .live else { return }
        switch state {
        case .connected, .completed:
            if dropBegan != nil { trace("media: back after \(Int((clock.now - (dropBegan ?? clock.now)) * 1000)) ms") }
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
        if stats.audioLevel >= Self.speakingLevel {
            if marks["first_voice"] == nil {
                mark("first_voice")
                trace("first agent audio \(ms(since: "answered")) ms after the answer (\(stats.codec ?? "codec unknown"))")
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

    /// Before any media: release everything and hand the call to the WebSocket.
    private func giveUp(_ reason: GraineRtcFallback, _ detail: String) {
        guard phase != .ended, phase != .live else { return }
        trace("giving up (\(reason.rawValue)): \(detail)")
        release(sendBye: true)
        emit(.unreachable(reason, detail: detail))
    }

    /// After media: the call is over.
    private func end(_ ending: GraineRtcEnding) {
        guard phase == .live else { return }
        if case .dropped(let why) = ending { trace("dropped: \(why)") }
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
        parts.audio.callEnds()
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
        sinkLock.unlock()
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
