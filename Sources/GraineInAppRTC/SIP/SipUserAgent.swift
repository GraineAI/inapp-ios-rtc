import Foundation

/*
 * THE CALL'S SIP USER AGENT — the subset of RFC 3261 (over a WebSocket, RFC
 * 7118) that the voice bar's SIP stack uses to place one call to Graine's
 * SBC, and nothing more:
 *
 *   REGISTER        once, answering the 401's digest challenge; refreshed while
 *                   the call lasts; withdrawn (Expires: 0) when it ends
 *   INVITE          to the application, answering the challenge (401 or 407)
 *                   with an ACK and a second INVITE; 1xx noted; the 2xx ACKed
 *                   at once to its Contact, on this same socket
 *   CANCEL / BYE    our hang-up, whichever the call's state needs; a 2xx that
 *                   arrives after our CANCEL is ACKed and then BYEd — the
 *                   socket kept until the dial has its final answer (shutDown)
 *   the dialog      their BYE (200, the call is over), their re-INVITE or
 *                   UPDATE (answered from the engine's current media), OPTIONS,
 *                   INFO, NOTIFY (200); anything unknown 405/501, never a crash
 *   session timers  as JsSIP keeps them: with no Session-Expires in the 2xx
 *                   we refresh with an UPDATE every 45 s (the SBC expects it)
 *
 * Everything runs on the clock's context; the socket's callbacks hop onto it.
 * Over a reliable socket nothing is retransmitted (JsSIP does not either).
 */
final class SipUserAgent {
    /// Why a request failed: the SIP status when there was one, and JsSIP's word for it.
    struct Failure: Error, Equatable {
        var code: Int?
        var cause: String

        static let connection = Failure(code: nil, cause: SipCauses.connectionError)
        static let timeout = Failure(code: nil, cause: SipCauses.requestTimeout)
    }

    enum Event {
        /// The socket opened; the REGISTER is on its way.
        case connected
        /// Registered: `seconds` from the socket's start to the 200 (the link's own pace, for the dial deadlines).
        case registered(seconds: Double)
        case registrationFailed(Failure)
        /// The socket is gone.
        case transportLost(String)
        /// The INVITE left (the first one, and after a challenge the one with credentials).
        case inviteSent
        /// A provisional reply (1xx) to the INVITE in flight: the SBC has it. Its first for each INVITE — after a
        /// challenge, the INVITE with credentials' own 100 Trying, which the answer is timed from — then any new status.
        case heard(Int)
        /// The INVITE was challenged (401 or 407) and has gone again with credentials: what was heard so far belonged
        /// to an INVITE now refused, and the INVITE in flight has heard nothing yet. A challenge is never `heard`.
        case challenged(Int)
        /// The INVITE was answered (and the 2xx ACKed): the SBC's answer SDP, and its call id for the log.
        case answered(sdp: String, callSid: String?)
        case inviteFailed(Failure)
        /// The agent's side hung up.
        case byeReceived
        /// A re-INVITE or UPDATE with an offer: the engine answers it from its media.
        case offerReceived(sdp: String, reply: (Result<String, Failure>) -> Void)
        /// A re-INVITE with no offer: the engine offers; the answer arrives in the ACK.
        case offerRequested(reply: (Result<String, Failure>) -> Void)
        case answerInAck(sdp: String)
        /// The dialog is gone without a BYE: 408/481 to one of our requests, or the session timer ran out.
        case dialogLost(String)
    }

    /// RFC 3261's 64×T1: how long a transaction may wait for its final answer.
    static let transactionTimeout = 32.0
    /// JsSIP's connection recovery: 2 s, doubling, at most 30 s.
    static let reconnectMin = 2.0
    static let reconnectMax = 30.0

    let identity: SipIdentity
    private let server: URL
    private let clock: RtcClock
    private let sockets: RtcSocketFactory
    private let random: SipRandom
    private let log: (String) -> Void
    private let onEvent: (Event) -> Void
    /// JsSIP's per-UA `jssip_id`: the first five characters of every call's Call-ID.
    private let callIdPrefix: String

    private var socket: RtcSocket?
    private(set) var isOpen = false
    private var connectStartedAt: Double?
    private var shuttingDown = false
    private var closed = false
    /// While a call is live, a lost socket is reconnected (and re-registered) rather than given up.
    var keepsTransport = false
    private var reconnectAttempt = 0
    private var reconnectTimer: RtcTimer?
    /// While it shuts down nobody else holds it: it holds itself until its socket is closed.
    private var finishing: SipUserAgent?

    // Registration (one Call-ID for the UA's life, CSeq counting up, a new From tag each time).
    private let regCallId: String
    private var regCSeq = 0
    private var regExpires: Int
    private var regTx: ClientTx?
    private(set) var registered = false
    private var everRegistered = false
    private var regRefreshTimer: RtcTimer?

    // The call.
    private var call: InviteTx?
    private(set) var dialog: SipDialog?
    private var dialogOver = false
    private var remoteSeq: Int?
    /// Their offerless re-INVITE was answered with our offer: their answer comes in the ACK.
    private var awaitingAckAnswer = false
    /// Our re-INVITE is out: theirs is refused 491 meanwhile.
    private var ourReinviteOut = false

    // In-dialog requests of ours (BYE, UPDATE, re-INVITE) and the un-REGISTER, by branch.
    private var pending: [String: ClientTx] = [:]

    // Session timers, as JsSIP runs them.
    private var sessionExpires = SipShape.sessionExpires
    private var weRefresh = true
    private var sessionTimersRunning = false
    private var sessionTimer: RtcTimer?

    init(
        server: URL,
        identity: SipIdentity,
        registerExpires: Int = 300,
        clock: RtcClock,
        sockets: RtcSocketFactory,
        random: SipRandom,
        log: @escaping (String) -> Void = { _ in },
        onEvent: @escaping (Event) -> Void
    ) {
        self.server = server
        self.identity = identity
        self.regExpires = registerExpires
        self.clock = clock
        self.sockets = sockets
        self.random = random
        self.log = log
        self.onEvent = onEvent
        self.callIdPrefix = random.token(5)
        self.regCallId = random.token(22)
    }

    /// A fresh identity for one user agent: the made-up Via host, Contact user and instance id.
    static func identity(username: String, realm: String, password: String, userAgent: String, random: SipRandom) -> SipIdentity {
        SipIdentity(
            username: username,
            realm: realm,
            password: password,
            viaHost: random.token(12) + ".invalid",
            contactUser: random.token(8),
            instanceId: random.uuid(),
            userAgent: userAgent
        )
    }

    // MARK: - Driving it

    /// Open the socket; the REGISTER follows the moment it is open.
    func start() {
        guard socket == nil, !closed else { return }
        connect()
    }

    /// Dial the application: `target` is `sip:app-{sid}@{realm}`, `headers` the X- headers in order.
    func invite(target: String, headers: [String], sdp: String) {
        guard !closed, call == nil, dialog == nil else { return }
        let request = SipWriter.invite(
            identity: identity,
            target: target,
            callId: callIdPrefix + random.token(15),
            cseq: random.initialCSeq(),
            fromTag: random.token(10),
            branch: random.branch(),
            headers: headers,
            sdp: sdp
        )
        call = InviteTx(request: request, target: target)
        sendInvite()
    }

    /// A new offer inside the call (an ICE restart): `done` gets their answer.
    func reinvite(sdp: String, done: @escaping (Result<String, Failure>) -> Void) {
        guard var d = dialog, !dialogOver, isOpen else {
            done(.failure(.connection))
            return
        }
        d.localSeq += 1
        dialog = d
        var extra = ["Contact: \(identity.dialogContact)", "Content-Type: application/sdp"]
        if sessionTimersRunning { extra.append("Session-Expires: \(sessionExpires);refresher=\(weRefresh ? "uac" : "uas")") }
        let request = SipWriter.inDialog(method: "INVITE", dialog: d, identity: identity, branch: random.branch(), cseq: d.localSeq, extra: extra, body: sdp)
        ourReinviteOut = true
        track(request) { [weak self] response, failure in
            guard let self = self else { return }
            self.ourReinviteOut = false
            if let response = response, let code = response.statusCode, (200...299).contains(code) {
                self.ackInDialog(cseq: request.cseq)
                self.sessionTimersFromResponse(response)
                if response.hasSdp {
                    done(.success(response.body))
                } else {
                    done(.failure(Failure(code: code, cause: SipCauses.badMediaDescription)))
                }
            } else {
                done(.failure(failure ?? Failure(code: response?.statusCode, cause: SipCauses.forCode(response?.statusCode ?? 0))))
            }
        }
    }

    /// Our hang-up: BYE in a call, CANCEL while it is being dialled (sent once a provisional proves the INVITE arrived).
    func hangUp() {
        if dialog != nil, !dialogOver {
            sendBye()
            return
        }
        guard var c = call, c.state == .calling || c.state == .proceeding else { return }
        c.canceled = true
        call = c
        if c.state == .proceeding { send(SipWriter.cancel(invite: c.request)) }
    }

    /**
     * The end, politely: withdraw the registration at once (it is challenged
     * too) and close the socket once nothing on it waits for an answer — the
     * un-REGISTER, a BYE, and a dial not yet answered, whose CANCEL earns a
     * 487 or whose answer crossing the CANCEL is ACKed and BYEd here: without
     * those the server's leg stays up, running an agent nobody hears. Or after
     * `grace`, whatever happens — at least `DialRules.abandonedDialGrace`
     * while a dial is unanswered. Anything already on its way has left first.
     */
    func shutDown(grace: Double = 2.0) {
        guard !closed, !shuttingDown else { return }
        shuttingDown = true
        finishing = self
        keepsTransport = false
        reconnectTimer?.cancel()
        sessionTimer?.cancel()
        regRefreshTimer?.cancel()
        clock.after(inviteInFlight ? max(grace, DialRules.abandonedDialGrace) : grace) { [weak self] in self?.close() }
        if registered && isOpen {
            registered = false
            sendRegister(expires: 0)
        }
        closeWhenIdle(after: 0.2)
    }

    /// An INVITE of ours is on its way and has no final answer yet: hanging up must CANCEL it, on this socket.
    var inviteInFlight: Bool {
        guard let c = call else { return false }
        return c.state == .calling || c.state == .proceeding
    }

    /// Shutting down, and nothing on the socket waits for an answer any more.
    private var idleWhileShuttingDown: Bool {
        shuttingDown && !closed && regTx == nil && pending.isEmpty && !inviteInFlight
    }

    /// Shutting down: close once nothing on the socket waits for an answer, `after` a moment for what was just sent.
    private func closeWhenIdle(after delay: Double = 0.05) {
        guard idleWhileShuttingDown else { return }
        clock.after(delay) { [weak self] in
            guard let self = self, self.idleWhileShuttingDown else { return }
            self.close()
        }
    }

    /// Close at once: nothing more is sent or heard.
    func close() {
        guard !closed else { return }
        closed = true
        isOpen = false
        reconnectTimer?.cancel()
        sessionTimer?.cancel()
        regRefreshTimer?.cancel()
        call?.timer?.cancel()
        regTx?.timer?.cancel()
        for tx in pending.values { tx.timer?.cancel() }
        pending = [:]
        socket?.close()
        socket = nil
        finishing = nil
    }

    // MARK: - The socket

    private func connect() {
        connectStartedAt = clock.now
        let events = RtcSocketEvents(
            opened: { [weak self] in self?.clock.run { self?.socketOpened() } },
            received: { [weak self] text in self?.clock.run { self?.receive(text) } },
            closed: { [weak self] _, detail in self?.clock.run { self?.socketClosed(detail) } }
        )
        socket = sockets.open(server, protocols: ["sip"], events: events)
    }

    private func socketOpened() {
        guard !closed else { return }
        isOpen = true
        reconnectAttempt = 0
        onEvent(.connected)
        sendRegister(expires: regExpires)
    }

    private func socketClosed(_ detail: String) {
        guard !closed else { return }
        isOpen = false
        socket = nil
        registered = false
        regTx?.timer?.cancel()
        regTx = nil
        regRefreshTimer?.cancel()
        // What was waiting on this socket will not be answered on it.
        if var c = call, c.state == .calling || c.state == .proceeding {
            c.timer?.cancel()
            c.state = .terminated
            call = c
            onEvent(.inviteFailed(.connection))
        }
        let waiting = pending
        pending = [:]
        for tx in waiting.values {
            tx.timer?.cancel()
            tx.completion(nil, .connection)
        }
        if shuttingDown {
            close()
            return
        }
        onEvent(.transportLost(detail))
        if keepsTransport {
            // JsSIP's connection recovery: the call's media does not need this socket, its BYE does.
            let delay = min(Self.reconnectMax, Self.reconnectMin * pow(2, Double(reconnectAttempt)))
            reconnectAttempt += 1
            log("sip: socket lost (\(detail)); reconnecting in \(Int(delay)) s")
            reconnectTimer = clock.after(delay) { [weak self] in
                guard let self = self, !self.closed, self.socket == nil else { return }
                self.connect()
            }
        }
    }

    private func send(_ request: SipRequest) {
        guard isOpen, let socket = socket else { return }
        socket.send(request.text)
    }

    private func sendRaw(_ text: String) {
        guard isOpen, let socket = socket else { return }
        socket.send(text)
    }

    // MARK: - Registration

    private func sendRegister(expires: Int) {
        regCSeq += 1
        let request = SipWriter.register(
            identity: identity, callId: regCallId, cseq: regCSeq, fromTag: random.token(10), branch: random.branch(), expires: expires
        )
        regTx?.timer?.cancel()
        var tx = ClientTx(request: request) { [weak self] response, failure in
            self?.registerAnswered(response, failure, expires: expires)
        }
        tx.timer = clock.after(Self.transactionTimeout) { [weak self] in
            guard let self = self, let current = self.regTx, current.request.branch == request.branch else { return }
            self.regTx = nil
            current.completion(nil, .timeout)
        }
        regTx = tx
        send(request)
    }

    private func registerAnswered(_ response: SipMessage?, _ failure: Failure?, expires: Int) {
        if expires == 0 {
            // The registration is withdrawn (or could not be): the socket goes once nothing else on it waits.
            closeWhenIdle()
            return
        }
        guard let response = response, let code = response.statusCode else {
            registered = false
            if !everRegistered { onEvent(.registrationFailed(failure ?? .connection)) }
            return
        }
        switch code {
        case 200...299:
            registered = true
            var granted = expires
            if let contact = response.headerValues("Contact").compactMap(SipNameAddr.parse).first(where: { $0.uri.contains(identity.contactUser) }),
               let value = contact.param("expires"), let n = Int(value) {
                granted = n
            } else if let header = response.header("Expires"), let n = Int(header) {
                granted = n
            }
            scheduleRegisterRefresh(Swift.max(10, granted))
            if !everRegistered {
                everRegistered = true
                onEvent(.registered(seconds: clock.now - (connectStartedAt ?? clock.now)))
            }
        case 423:
            // Interval too brief: register again at the registrar's minimum.
            if let min = response.header("Min-Expires").flatMap(Int.init) {
                regExpires = Swift.max(min, 10)
                sendRegister(expires: regExpires)
            } else if !everRegistered {
                onEvent(.registrationFailed(Failure(code: code, cause: SipCauses.sipFailureCode)))
            }
        default:
            registered = false
            if !everRegistered { onEvent(.registrationFailed(Failure(code: code, cause: SipCauses.forCode(code)))) }
            else { log("sip: re-REGISTER refused (\(code))") }
        }
    }

    /// JsSIP's refresh point: half the interval, plus up to half of what is left above 32 s.
    private func scheduleRegisterRefresh(_ expires: Int) {
        regRefreshTimer?.cancel()
        let spread = Double(expires) / 2 - 32
        let seconds: Double = expires > 64
            ? Double(expires) / 2 + (spread > 0 ? Double.random(in: 0..<spread) : 0)
            : Double(expires) - 5
        regRefreshTimer = clock.after(Swift.max(5, seconds)) { [weak self] in
            guard let self = self, self.registered, !self.shuttingDown else { return }
            self.sendRegister(expires: self.regExpires)
        }
    }

    // MARK: - The INVITE

    private func sendInvite() {
        guard var c = call else { return }
        c.state = .calling
        c.timer?.cancel()
        let branch = c.request.branch
        c.timer = clock.after(Self.transactionTimeout) { [weak self] in
            guard let self = self, let now = self.call, now.request.branch == branch, now.state == .calling || now.state == .proceeding else { return }
            self.call?.state = .terminated
            self.onEvent(.inviteFailed(.timeout))
        }
        call = c
        guard isOpen else {
            call?.state = .terminated
            onEvent(.inviteFailed(.connection))
            return
        }
        send(c.request)
        onEvent(.inviteSent)
    }

    private func inviteResponse(_ response: SipMessage, code: Int) {
        guard var c = call else { return }
        // A 2xx retransmitted after the dialog exists: ACK it again; one from a fork gets ACK and BYE.
        if (200...299).contains(code), let d = dialog {
            if response.toTag == d.remoteTag {
                ackInDialog(cseq: d.inviteSeq)
            } else if let stray = dialogFor(response) {
                send(SipWriter.inDialog(method: "ACK", dialog: stray, identity: identity, branch: random.branch(), cseq: stray.inviteSeq))
                send(SipWriter.inDialog(method: "BYE", dialog: stray, identity: identity, branch: random.branch(), cseq: stray.inviteSeq + 1))
            }
            return
        }
        guard c.state == .calling || c.state == .proceeding else {
            // A final answer repeated: the transaction ACKs a non-2xx again.
            if code >= 300, c.state == .completed { send(SipWriter.ackFailure(invite: c.request, responseTo: response.header("To") ?? "")) }
            return
        }
        switch code {
        case 100...199:
            let first = !c.heard
            c.heard = true
            c.state = .proceeding
            call = c
            if c.canceled {
                send(SipWriter.cancel(invite: c.request))
                return
            }
            if first || code > 100 { onEvent(.heard(code)) }

        case 200...299:
            c.timer?.cancel()
            c.state = .accepted
            call = c
            guard let made = dialogFor(response) else {
                c.state = .terminated
                call = c
                onEvent(.inviteFailed(Failure(code: code, cause: SipCauses.dialogError)))
                return
            }
            dialog = made
            ackInDialog(cseq: made.inviteSeq)
            if c.canceled {
                // Answered after we hung up: ACK it, then end it.
                sendBye()
                return
            }
            guard response.hasSdp else {
                sendBye()
                onEvent(.inviteFailed(Failure(code: code, cause: SipCauses.badMediaDescription)))
                return
            }
            sessionTimersFromResponse(response)
            onEvent(.answered(sdp: response.body, callSid: response.header("X-Call-Sid")))

        default:
            // The transaction ACKs every non-2xx final answer, with the INVITE's branch.
            send(SipWriter.ackFailure(invite: c.request, responseTo: response.header("To") ?? ""))
            c.timer?.cancel()
            if (code == 401 || code == 407), !c.challenged, !c.canceled,
               let authorization = answerChallenge(response, for: c.request) {
                // The same INVITE again with credentials: CSeq + 1, a new branch, the same Call-ID, tag and SDP.
                // It is a new INVITE, and it has heard nothing yet: what the refused one heard was not its reply.
                var again = c.request
                again.set("CSeq", "\(c.request.cseq + 1) INVITE")
                again.set("Via", "SIP/2.0/WSS \(identity.viaHost);branch=\(random.branch())")
                again.set(code == 401 ? "Authorization" : "Proxy-Authorization", authorization)
                c.request = again
                c.challenged = true
                c.heard = false
                call = c
                onEvent(.challenged(code))
                sendInvite()
                return
            }
            c.state = .completed
            call = c
            if c.canceled { return }
            onEvent(.inviteFailed(Failure(code: code, cause: SipCauses.forCode(code))))
        }
    }

    /// The dialog a 2xx makes (JsSIP's Dialog 'UAC'): its Contact is where in-dialog requests go.
    private func dialogFor(_ response: SipMessage) -> SipDialog? {
        guard let c = call, let remoteTag = response.toTag, !remoteTag.isEmpty,
              let contact = response.headerValues("Contact").first.flatMap(SipNameAddr.parse),
              let fromTag = c.request.value("From").flatMap(SipNameAddr.parse)?.param("tag") else { return nil }
        return SipDialog(
            callId: c.request.callId,
            localTag: fromTag,
            remoteTag: remoteTag,
            localUri: identity.aor,
            remoteUri: c.target,
            remoteTarget: contact.uri,
            routeSet: response.headerValues("Record-Route").reversed(),
            localSeq: c.request.cseq,
            inviteSeq: c.request.cseq
        )
    }

    private func ackInDialog(cseq: Int) {
        guard let d = dialog else { return }
        send(SipWriter.inDialog(method: "ACK", dialog: d, identity: identity, branch: random.branch(), cseq: cseq))
    }

    private func sendBye() {
        guard var d = dialog, !dialogOver else { return }
        dialogOver = true
        sessionTimer?.cancel()
        d.localSeq += 1
        dialog = d
        let request = SipWriter.inDialog(method: "BYE", dialog: d, identity: identity, branch: random.branch(), cseq: d.localSeq)
        track(request) { _, _ in }
    }

    /// The credentials answering a 401/407 for `request`, or nil when the challenge cannot be answered.
    private func answerChallenge(_ response: SipMessage, for request: SipRequest) -> String? {
        let header = response.statusCode == 407 ? response.header("Proxy-Authenticate") : response.header("WWW-Authenticate")
        guard let raw = header, let challenge = SipChallenge.parse(raw), !identity.password.isEmpty else { return nil }
        return SipDigest.authorization(
            username: identity.username,
            password: identity.password,
            method: request.method,
            uri: request.uri,
            body: request.body ?? "",
            challenge: challenge,
            cnonce: random.token(12)
        )
    }

    // MARK: - Our requests inside the dialog (and the un-REGISTER)

    private func track(_ request: SipRequest, completion: @escaping (SipMessage?, Failure?) -> Void) {
        guard let branch = request.branch else { return }
        var tx = ClientTx(request: request, completion: completion)
        tx.timer = clock.after(Self.transactionTimeout) { [weak self] in
            guard let self = self, let done = self.pending.removeValue(forKey: branch) else { return }
            done.completion(nil, .timeout)
            self.inDialogFailed(code: 408, method: request.method)
        }
        pending[branch] = tx
        send(request)
    }

    private func clientResponse(_ response: SipMessage, code: Int, branch: String) {
        guard let tx = pending[branch] else { return }
        if code < 200 { return }
        if (code == 401 || code == 407), !tx.challenged, let authorization = answerChallenge(response, for: tx.request) {
            pending.removeValue(forKey: branch)
            tx.timer?.cancel()
            var again = tx.request
            if again.method == "INVITE", code >= 300 { send(SipWriter.ackFailure(invite: again, responseTo: response.header("To") ?? "")) }
            again.set("CSeq", "\(tx.request.cseq + 1) \(tx.request.method)")
            again.set("Via", "SIP/2.0/WSS \(identity.viaHost);branch=\(random.branch())")
            again.set(code == 401 ? "Authorization" : "Proxy-Authorization", authorization)
            if var d = dialog, again.method != "REGISTER" {
                d.localSeq = Swift.max(d.localSeq, again.cseq)
                dialog = d
            }
            if again.method == "REGISTER" { regCSeq = again.cseq }
            var next = ClientTx(request: again, completion: tx.completion)
            next.challenged = true
            let newBranch = again.branch ?? ""
            next.timer = clock.after(Self.transactionTimeout) { [weak self] in
                guard let self = self, let done = self.pending.removeValue(forKey: newBranch) else { return }
                done.completion(nil, .timeout)
            }
            pending[newBranch] = next
            send(again)
            return
        }
        pending.removeValue(forKey: branch)
        tx.timer?.cancel()
        if tx.request.method == "INVITE", code >= 300 {
            send(SipWriter.ackFailure(invite: tx.request, responseTo: response.header("To") ?? ""))
        }
        tx.completion(response, nil)
        if code == 408 || code == 481 { inDialogFailed(code: code, method: tx.request.method) }
    }

    /// RFC 3261 §12.2.1.2: 408 or 481 to a request inside the dialog means the dialog is gone.
    private func inDialogFailed(code: Int, method: String) {
        guard method != "REGISTER", dialog != nil, !dialogOver else { return }
        dialogOver = true
        sessionTimer?.cancel()
        onEvent(.dialogLost("\(method) answered \(code)"))
    }

    // MARK: - Session timers (JsSIP's: on by default; the trace shows the SBC accepting them)

    private func sessionTimersFromResponse(_ response: SipMessage) {
        if let se = response.sessionExpires, se.seconds >= SipShape.minSessionExpires {
            sessionExpires = se.seconds
            weRefresh = (se.refresher ?? "uac") == "uac"
        } else {
            sessionExpires = SipShape.sessionExpires
            weRefresh = true
        }
        runSessionTimer()
    }

    /// Their refresh carried (or lacked) Session-Expires: what to put in our answer.
    private func sessionTimersFromRequest(_ request: SipMessage) -> String {
        let refresher: String
        if let se = request.sessionExpires, se.seconds >= SipShape.minSessionExpires {
            sessionExpires = se.seconds
            refresher = se.refresher ?? "uas"
        } else {
            sessionExpires = SipShape.sessionExpires
            refresher = "uas"
        }
        weRefresh = refresher == "uas"
        runSessionTimer()
        return "Session-Expires: \(sessionExpires);refresher=\(refresher)"
    }

    private func runSessionTimer() {
        sessionTimersRunning = true
        sessionTimer?.cancel()
        guard !dialogOver else { return }
        if weRefresh {
            sessionTimer = clock.after(Double(sessionExpires) / 2) { [weak self] in self?.refreshSession() }
        } else {
            // Nobody refreshed: the session is over (JsSIP ends it with a BYE).
            sessionTimer = clock.after(Double(sessionExpires) * 1.1) { [weak self] in
                guard let self = self, !self.dialogOver else { return }
                self.sendBye()
                self.onEvent(.dialogLost("session timer expired"))
            }
        }
    }

    /// The refresh: an UPDATE with no body, our Contact and `refresher=uac`.
    private func refreshSession() {
        guard var d = dialog, !dialogOver, isOpen else { return }
        d.localSeq += 1
        dialog = d
        let extra = ["Contact: \(identity.dialogContact)", "Session-Expires: \(sessionExpires);refresher=\(weRefresh ? "uac" : "uas")"]
        let request = SipWriter.inDialog(method: "UPDATE", dialog: d, identity: identity, branch: random.branch(), cseq: d.localSeq, extra: extra)
        track(request) { [weak self] response, _ in
            guard let self = self, let response = response, let code = response.statusCode else { return }
            if (200...299).contains(code) {
                self.sessionTimersFromResponse(response)
            } else {
                // A refused refresh is not the end of the call (nor is it in JsSIP); no more refreshes.
                self.log("sip: session refresh answered \(code)")
            }
        }
    }

    // MARK: - What arrives

    private func receive(_ text: String) {
        guard !closed else { return }
        guard let message = SipParser.parse(text) else {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { log("sip: dropped a message it could not read (\(text.utf8.count) bytes)") }
            return
        }
        if let code = message.statusCode {
            response(message, code: code)
        } else {
            request(message)
        }
    }

    private func response(_ message: SipMessage, code: Int) {
        guard let branch = message.topViaBranch, let cseq = message.cseq else { return }
        if let tx = regTx, tx.request.branch == branch {
            if code < 200 { return }
            if (code == 401 || code == 407), !tx.challenged, let authorization = answerChallenge(message, for: tx.request) {
                tx.timer?.cancel()
                regCSeq += 1
                var again = tx.request
                again.set("CSeq", "\(regCSeq) REGISTER")
                again.set("Via", "SIP/2.0/WSS \(identity.viaHost);branch=\(random.branch())")
                again.set(code == 401 ? "Authorization" : "Proxy-Authorization", authorization)
                var next = ClientTx(request: again, completion: tx.completion)
                next.challenged = true
                let newBranch = again.branch
                next.timer = clock.after(Self.transactionTimeout) { [weak self] in
                    guard let self = self, let current = self.regTx, current.request.branch == newBranch else { return }
                    self.regTx = nil
                    current.completion(nil, .timeout)
                }
                regTx = next
                send(again)
                return
            }
            regTx = nil
            tx.timer?.cancel()
            tx.completion(message, nil)
            return
        }
        if let c = call, cseq.method == "INVITE", c.request.callId == message.callId,
           c.request.branch == branch || (dialog != nil && cseq.number == dialog?.inviteSeq) {
            inviteResponse(message, code: code)
            // A dial let go while it shut down has its final answer now (its BYE, if it needs one, is on its way).
            closeWhenIdle()
            return
        }
        if pending[branch] != nil {
            clientResponse(message, code: code, branch: branch)
            closeWhenIdle()
        }
    }

    private func request(_ message: SipMessage) {
        guard let method = message.method else { return }
        func reply(_ code: Int, extra: [String] = [], body: String? = nil) {
            self.sendRaw(SipWriter.response(to: message, code: code, extra: extra, body: body, newTag: { self.random.token(10) }))
        }
        if method == "ACK" {
            if awaitingAckAnswer, let d = dialog, message.callId == d.callId {
                awaitingAckAnswer = false
                if message.hasSdp { onEvent(.answerInAck(sdp: message.body)) }
            }
            return
        }
        // Outside any dialog: nothing here takes a new call.
        guard let toTag = message.toTag, !toTag.isEmpty else {
            switch method {
            case "OPTIONS", "NOTIFY", "MESSAGE": reply(200)
            case "BYE", "CANCEL": reply(481)
            default: reply(SipShape.allow.split(separator: ",").contains(Substring(method)) ? 405 : 501)
            }
            return
        }
        guard let d = dialog, !dialogOver, message.callId == d.callId, toTag == d.localTag, message.fromTag == d.remoteTag else {
            reply(481)
            return
        }
        // CSeq order inside the dialog (JsSIP refuses an older one with 500).
        if let n = message.cseq?.number {
            if let last = remoteSeq, n < last {
                reply(500)
                return
            }
            remoteSeq = n
        }
        switch method {
        case "BYE":
            reply(200)
            dialogOver = true
            sessionTimer?.cancel()
            onEvent(.byeReceived)

        case "INVITE", "UPDATE":
            if method == "INVITE" && ourReinviteOut {
                reply(491)
                return
            }
            let sessionHeader = sessionTimersFromRequest(message)
            let headers = ["Contact: \(identity.dialogContact)", sessionHeader]
            if message.hasSdp {
                onEvent(.offerReceived(sdp: message.body, reply: { [weak self] result in
                    self?.clock.run {
                        switch result {
                        case .success(let answer): reply(200, extra: headers, body: answer)
                        case .failure: reply(488)
                        }
                    }
                }))
            } else if method == "INVITE" {
                onEvent(.offerRequested(reply: { [weak self] result in
                    self?.clock.run {
                        switch result {
                        case .success(let offer):
                            self?.awaitingAckAnswer = true
                            reply(200, extra: headers, body: offer)
                        case .failure:
                            reply(500)
                        }
                    }
                }))
            } else {
                // An UPDATE with no body: a session refresh.
                reply(200, extra: headers)
            }

        case "OPTIONS", "INFO", "NOTIFY", "MESSAGE", "PRACK", "CANCEL":
            reply(200)

        case "REFER":
            reply(603)

        default:
            reply(SipShape.allow.split(separator: ",").contains(Substring(method)) ? 405 : 501)
        }
    }
}

/// A request of ours waiting for its final answer.
private struct ClientTx {
    var request: SipRequest
    var challenged = false
    var timer: RtcTimer?
    let completion: (SipMessage?, SipUserAgent.Failure?) -> Void

    init(request: SipRequest, completion: @escaping (SipMessage?, SipUserAgent.Failure?) -> Void) {
        self.request = request
        self.completion = completion
    }
}

/// The INVITE client transaction (RFC 3261 §17.1.1), and what the caller asked of it.
private struct InviteTx {
    enum State { case calling, proceeding, accepted, completed, terminated }
    var request: SipRequest
    let target: String
    var state = State.calling
    var challenged = false
    var canceled = false
    /// The INVITE in flight has had a provisional reply; a new one after a challenge starts unheard.
    var heard = false
    var timer: RtcTimer?

    init(request: SipRequest, target: String) {
        self.request = request
        self.target = target
    }
}

/// JsSIP's cause words (JsSIP.C.causes), which the voice bar's dial rules read.
enum SipCauses {
    static let connectionError = "Connection Error"
    static let requestTimeout = "Request Timeout"
    static let sipFailureCode = "SIP Failure Code"
    static let internalError = "Internal Error"
    static let busy = "Busy"
    static let rejected = "Rejected"
    static let redirected = "Redirected"
    static let unavailable = "Unavailable"
    static let notFound = "Not Found"
    static let addressIncomplete = "Address Incomplete"
    static let incompatibleSdp = "Incompatible SDP"
    static let authenticationError = "Authentication Error"
    static let badMediaDescription = "Bad Media Description"
    static let dialogError = "Dialog Error"
    static let webrtcError = "WebRTC Error"

    /// JsSIP's Utils.sipErrorCause.
    static func forCode(_ code: Int) -> String {
        switch code {
        case 300, 301, 302, 305, 380: return redirected
        case 486, 600: return busy
        case 403, 603: return rejected
        case 404, 604: return notFound
        case 480, 410, 408, 430: return unavailable
        case 484, 424: return addressIncomplete
        case 488, 606: return incompatibleSdp
        case 401, 407: return authenticationError
        default: return sipFailureCode
        }
    }
}
