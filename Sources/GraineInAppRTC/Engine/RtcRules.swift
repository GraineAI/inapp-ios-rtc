import Foundation

/*
 * THE VOICE BAR'S RULES, PORTED AS THEY ARE — pure, so a Mac proves them.
 *
 *   IceGathering   when to stop waiting for ICE candidates and send the offer
 *                  (the SBC does not trickle, so the offer must be complete,
 *                  and a dead network interface must not hold the call)
 *   DialRules      how long a dial may go unanswered, and whether a failed one
 *                  is tried once more on a fresh connection or handed to the
 *                  WebSocket
 *   SdpCodecs      Opus first, then PCMU, by reordering the m=audio list
 */

enum IceCandidateKind: String {
    case host, srflx, prflx, relay, end, unknown
}

enum IceGathering {
    /// A public candidate arrives in tens of milliseconds; this is fifteen times that.
    static let capSeconds = 1.5
    /// With TURN, the relay is one more round trip: worth waiting for, up to this.
    static let relayCapSeconds = 2.5

    /// The `typ` of a candidate line, or `.end` for the end of candidates (nil or empty).
    static func kind(_ line: String?) -> IceCandidateKind {
        guard let line = line, !line.isEmpty else { return .end }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let at = words.firstIndex(of: "typ"), at + 1 < words.count else { return .unknown }
        return IceCandidateKind(rawValue: String(words[at + 1])) ?? .unknown
    }

    /**
     * Stop now and send the offer? A relay is the surest path there is; a
     * server-reflexive one is a public path — enough unless TURN is configured,
     * when the relay is coming and is the one a carrier NAT needs; the end of
     * candidates is the end; and the cap stops the wait for a dead interface.
     */
    static func endNow(_ kind: IceCandidateKind, elapsed: Double, cap: Double, wantRelay: Bool) -> Bool {
        if kind == .relay { return true }
        if kind == .srflx && !wantRelay { return true }
        if kind == .end { return true }
        return elapsed >= cap
    }

    /// Does this ICE configuration include a TURN server at all?
    static func hasTurn(_ servers: [RtcIceServer]) -> Bool {
        servers.contains { server in
            server.urls.contains { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("turn:") || $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("turns:") }
        }
    }

    static func cap(for servers: [RtcIceServer]) -> Double {
        hasTurn(servers) ? relayCapSeconds : capSeconds
    }

    /**
     * THE WAIT FOR THIS GATHERING, on the link it is on (the voice bar's
     * gatherCapMs). Without TURN: the public-candidate cap, as always. With
     * TURN and a server-reflexive candidate in hand: the relay cap, as always —
     * UDP works and the relay is a spare. With TURN and no UDP path yet: the
     * relay may be the only path, and on a slow link its allocation (a TCP and
     * a TLS handshake to the relay, then the allocation) takes longer, so the
     * cap grows with the link's pace, to twice at most.
     */
    static func cap(wantRelay: Bool, pace: Double, sawSrflx: Bool) -> Double {
        guard wantRelay else { return capSeconds }
        if sawSrflx { return relayCapSeconds }
        let p = pace.isFinite ? min(2, max(1, pace)) : 1
        return (relayCapSeconds * p * 1000).rounded() / 1000
    }
}

/**
 * HOW SLOW THIS LINK IS — the voice bar's networkPace: 1 on a good link, up to
 * `max`. The largest of what the call measured, each against a good mobile
 * link: a registration of 2 s (the server's own auth takes up to 1.8 s at busy
 * hours, so it is a generous yardstick), a warm-socket probe of 0.8 s, a media
 * round trip of 250 ms. Nothing measured is a good link: every deadline scaled
 * by it only ever grows from its base, never shrinks.
 */
enum RtcPace {
    static let max = 2.5

    static func of(registerSeconds: Double? = nil, probeSeconds: Double? = nil, roundTripSeconds: Double? = nil) -> Double {
        func ratio(_ value: Double?, _ good: Double) -> Double {
            guard let v = value, v.isFinite, v > 0 else { return 0 }
            return v / good
        }
        let slowest = Swift.max(1, ratio(registerSeconds, 2), ratio(probeSeconds, 0.8), ratio(roundTripSeconds, 0.25))
        return (Swift.min(max, slowest) * 10).rounded() / 10
    }

    /// A pace as the deadlines read it: never under 1, never over `max`.
    static func clamp(_ pace: Double) -> Double {
        pace.isFinite ? Swift.min(max, Swift.max(1, pace)) : 1
    }
}

/// What this side gathered for a dial, by kind — a relay by the protocol it reaches the relay with.
struct RtcGathered: Equatable {
    var host = 0
    var srflx = 0
    var relayUdp = 0
    var relayTcp = 0
    var relayTls = 0
    /// A relay whose protocol could not be told: never read as evidence that UDP is blocked.
    var relayUnknown = 0

    var total: Int { host + srflx + relayUdp + relayTcp + relayTls + relayUnknown }

    /**
     * One candidate line, and the TURN URL libwebrtc says it came from when it
     * says: `turns:` reaches its relay over TLS, `turn:` with `transport=tcp`
     * over TCP, any other `turn:` over UDP. A relay with no URL is unknown.
     */
    mutating func add(_ line: String, serverUrl: String? = nil) {
        switch IceGathering.kind(line) {
        case .host: host += 1
        case .srflx: srflx += 1
        case .relay:
            let url = (serverUrl ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if url.hasPrefix("turns:") { relayTls += 1 }
            else if url.hasPrefix("turn:") { if url.contains("transport=tcp") { relayTcp += 1 } else { relayUdp += 1 } }
            else { relayUnknown += 1 }
        default: break
        }
    }
}

/// What the connection's statistics say about its checks — the parts the recovery reads.
struct RtcIceReading: Equatable {
    var pairs = 0
    var succeeded = 0
    var inProgress = 0
    var failed = 0
    var requestsSent = 0
    var responsesReceived = 0
    var requestsReceived = 0
    var bytesReceived = 0
    var dtlsState: String?
}

enum RtcSetupStep: Equatable {
    case up, wait, act
}

/**
 * WEBRTC STAYS UP ON A WEAK NETWORK — the voice bar's rtc-resilience rules,
 * pure. A call in trouble recovers INSIDE WebRTC first: a slow link is waited
 * for, a path that will not come up (or was lost) gets an ICE restart in the
 * same call, UDP that looks blocked gets the relays over TCP and TLS alone,
 * and nothing is restarted or redialled into no network. Numbers as the web.
 */
enum RtcResilience {
    /// Answered, no media path yet: this × pace before anything is done (DialRules.iceConnectDeadline, unchanged).
    static func mediaDeadline(pace: Double) -> Double { DialRules.iceConnectDeadline * RtcPace.clamp(pace) }
    /// A setup still making progress gets twice its deadline, at most 30 s.
    static func mediaHardCap(pace: Double) -> Double { min(2 * mediaDeadline(pace: pace), 30) }
    /// After an ICE restart is sent, the new path has this long (6 s × pace, at most 15 s)…
    static func restartWindow(pace: Double) -> Double { min(6 * RtcPace.clamp(pace), 15) }
    /// …and twice that while it is still making progress, at most 24 s.
    static func restartHardCap(pace: Double) -> Double { min(2 * restartWindow(pace: pace), 24) }
    /// Nothing in flight at all this long after the answer (2.5 s × pace): restarted now, not at the deadline.
    static func earlyRestart(pace: Double) -> Double { 2.5 * RtcPace.clamp(pace) }
    /// A lost path, counting only time with a network, restarts included: given up after this (15 s × pace, at most 30 s).
    static func lostGiveUp(pace: Double) -> Double { min(15 * RtcPace.clamp(pace), 30) }
    /// A path lost mid-call gets its first restart this long after it went (at once when ICE says failed).
    static let restartAfter = 3.0
    /// Offline this long with the path lost: dropped.
    static let offlineHold = 30.0
    /// The network came back: ICE heals most paths within a round trip or two, so a restart waits this long first.
    static let onlineSettle = 2.0
    /// A restart that cannot be sent yet (no network, its socket reconnecting, another offer in flight) is tried again this often.
    static let restartRetry = 1.0
    /// How often a setup still making progress is looked at again.
    static let progressLook = 1.0
    /// ICE restarts per trouble: the first, and a second only when something changed.
    static let maxRestarts = 2
    /// A redial that would go into no network waits this long for the network.
    static let redialOfflineWait = 15.0

    /// An answered call with no media path: wait, or act? Never cut a setup still making progress — until its hard cap.
    static func setupStep(pathUp: Bool, progressing: Bool, elapsed: Double, deadline: Double, hardCap: Double) -> RtcSetupStep {
        if pathUp { return .up }
        if elapsed < deadline - 1e-9 { return .wait }
        if progressing && elapsed < hardCap - 1e-9 { return .wait }
        return .act
    }

    /**
     * May this trouble get (another) ICE restart? The first always may. A
     * second only when something changed that a new gathering can use: the
     * network itself, or UDP now looks blocked and the relays over TCP and TLS
     * were not tried alone yet. A refusal ends them: the far side refuses again.
     */
    static func restartPermitted(restarts: Int, networkChanged: Bool, udpBlocked: Bool, relayOnlyTried: Bool, refused: Bool) -> Bool {
        if refused { return false }
        if restarts <= 0 { return true }
        if restarts >= maxRestarts { return false }
        return networkChanged || (udpBlocked && !relayOnlyTried)
    }

    /// Nothing in flight: no candidate pair, or every one failed. A reading that could not be taken says nothing.
    static func nothingInFlight(_ reading: RtcIceReading?) -> Bool {
        guard let r = reading else { return false }
        return r.pairs == 0 || r.failed == r.pairs
    }

    /// Between two readings: a check answered, a check from the far side, bytes in, the handshake moving, a pair succeeding.
    static func progressed(from before: RtcIceReading?, to now: RtcIceReading?) -> Bool {
        guard let a = before, let b = now else { return false }
        return b.responsesReceived > a.responsesReceived || b.requestsReceived > a.requestsReceived || b.succeeded > a.succeeded
            || b.bytesReceived > a.bytesReceived || (b.dtlsState != nil && b.dtlsState != a.dtlsState) || b.pairs > a.pairs
    }

    /// A TURN URL that reaches its relay over TCP or TLS.
    static func isTcpTlsRelay(_ url: String) -> Bool {
        let u = url.trimmingCharacters(in: .whitespaces).lowercased()
        return u.hasPrefix("turns:") || (u.hasPrefix("turn:") && u.contains("transport=tcp"))
    }

    /// The servers cut down to the relays over TCP and TLS, credentials kept; empty when there are none.
    static func tcpTlsRelays(_ servers: [RtcIceServer]) -> [RtcIceServer] {
        servers.compactMap { server in
            let urls = server.urls.filter(isTcpTlsRelay)
            return urls.isEmpty ? nil : RtcIceServer(urls: urls, username: server.username, credential: server.credential)
        }
    }

    /**
     * DOES UDP LOOK BLOCKED? Nothing public came back over UDP — no
     * server-reflexive candidate, no relay reached over UDP — while a relay over
     * TCP or TLS did, or one is configured to try. Not judged before anything
     * was gathered at all: a device that gathered nothing has another problem.
     */
    static func udpLooksBlocked(_ gathered: RtcGathered, servers: [RtcIceServer]) -> Bool {
        guard gathered.total > 0, gathered.srflx == 0, gathered.relayUdp == 0, gathered.relayUnknown == 0 else { return false }
        return gathered.relayTcp + gathered.relayTls > 0 || !tcpTlsRelays(servers).isEmpty
    }

    /// How many candidates an SDP carries: an offer with none cannot make a path.
    static func candidateCount(_ sdp: String) -> Int {
        sdp.components(separatedBy: "\n").filter { $0.hasPrefix("a=candidate:") }.count
    }
}

/// What a dial that failed before it was answered should become.
enum DialVerdict: Equatable {
    /// We hung up: nobody else needs telling.
    case ignore
    /// The network's fault and this call has a dial left: register afresh and INVITE again.
    case redial
    /// Anything else, or out of dials: carry the conversation on the WebSocket.
    case fallback
}

enum DialRules {
    /// The first dial, and one more on a fresh connection.
    static let maxDials = 2
    /// From the INVITE leaving to the answer. Production answers in 0.2–0.9 s.
    static let answerDeadline = 15.0
    /**
     * From the SBC's first provisional reply to the AUTHENTICATED INVITE, to the answer. The SBC
     * replies the moment it has the INVITE, and a healthy call is answered right after: 37 ms median
     * on production, measured at the SBC on 18 Oct 2026. One that has said "trying" and then nothing
     * for half a second is stuck — a feature server that took the call and never answered — so it is
     * cancelled and dialled once more on a fresh connection. A seatbelt, and a short one: 0.10.2's
     * 3 s was 80× a normal answer and only delayed the fallback; this is still ~13× the median, so a
     * healthy call never trips it.
     *
     * The SBC challenges every INVITE (401 or 407) and the INVITE goes again with credentials, so the
     * first reply a dial hears belongs to an INVITE that is about to be refused — and the challenge
     * itself is a reply too. Timed from either, this half second also had to hold the challenge, the
     * second INVITE's whole round trip and the server's answer time, and a healthy call on a slow
     * mobile link was dialled twice (20 Oct 2026). So a challenge is not "heard": a clock started
     * before it stops there, and starts again at the first provisional reply to the INVITE with
     * credentials (RtcCallEngine, `.challenged`).
     */
    static let answerAfterHeard = 0.5

    /// `answerAfterHeard` on the link the dial is on: exactly half a second on a good one, up to 1.25 s on a measured slow one.
    static func answerAfterHeard(pace: Double) -> Double {
        (answerAfterHeard * RtcPace.clamp(pace) * 1000).rounded() / 1000
    }

    /**
     * …and a third dial, when the failure was the LINK's: nothing came back to
     * the INVITE, the socket closed under it, a request timed out on the way, or
     * the server refused it with 491 for its own race (a +300 ms link on
     * production, 26 Oct 2026: the INVITE with credentials answered 491 and the
     * call went to the WebSocket at once). None of these dials was answered as
     * far as this side can tell, and an answer that turns up late for one is
     * ACKed and ended with a BYE on its own socket — so the third INVITE never
     * stands beside a second greeting. A dial heard and not answered keeps two.
     */
    static let maxDialsOnLinkFailure = 3
    /// The link's own failures, before any answer.
    static let linkCauses: Set<String> = ["no_response", SipCauses.connectionError, SipCauses.requestTimeout]
    /**
     * How long a dial given up on keeps its socket for its own ending: its CANCEL and the 487, or the
     * ACK and BYE of an answer that crossed the CANCEL, all travel on the socket the dial was placed
     * on. Closed sooner (it used to go as soon as its un-REGISTER was answered), a late reply found it
     * gone and the server's leg stayed up — its agent running beside the redial's — until the server
     * gave up on its ACK. A few round trips on the slowest link a call still connects on. The
     * registration is withdrawn at once.
     */
    static let abandonedDialGrace = 4.0
    /// Answered, and still no media path after this: the customer's patience, not ICE's 30 s.
    static let iceConnectDeadline = 8.0
    /// The REGISTER's bound: success, an explicit refusal, or this.
    static let registerDeadline = 15.0
    /// A credential with less than this left is minted afresh for the second dial.
    static let credentialMinRemaining = 20.0

    /**
     * From the INVITE leaving to any reply to the INVITE in flight — after a
     * challenge, the one with credentials. The SBC answers 100 Trying the
     * moment it has the request, so silence past this is a socket that is not
     * delivering. Twice the link's own registration time, 3–8 s; 4 s unknown.
     */
    static func heardDeadline(registerSeconds: Double?) -> Double {
        guard let r = registerSeconds, r.isFinite, r > 0 else { return 4 }
        return min(8, max(3, (r * 2 * 1000).rounded() / 1000))
    }

    /// Causes that are the network's or the socket's — a fresh connection can fix them (JsSIP's words, plus two of ours).
    static let networkCauses: Set<String> = [
        "no_response", "no_answer",
        SipCauses.connectionError, SipCauses.requestTimeout, SipCauses.unavailable, SipCauses.sipFailureCode,
        SipCauses.webrtcError, SipCauses.internalError, "No Answer", "No ACK", SipCauses.dialogError, "RTP Timeout",
        // A credential the SBC no longer takes: a fresh mint is the fix.
        SipCauses.authenticationError,
    ]

    /// The voice bar's dialFailureVerdict.
    static func verdict(cause: String, code: Int?, dialsSoFar: Int) -> DialVerdict {
        if cause == "Canceled" || cause == "User Denied Media Access" { return .ignore }
        // The link's own failures — and the server's 491 — earn a third dial.
        if (linkCauses.contains(cause) || code == 491) && dialsSoFar < maxDialsOnLinkFailure { return .redial }
        // A "SIP Failure Code" is the network's only when it is a 5xx or carries no code.
        let networkish = networkCauses.contains(cause) && (cause != SipCauses.sipFailureCode || code == nil || code! >= 500)
        if networkish && dialsSoFar < maxDials { return .redial }
        return .fallback
    }

    /// A failure that may earn the third dial (and so a second fresh connection).
    static func isLinkFailure(cause: String, code: Int?) -> Bool {
        linkCauses.contains(cause) || code == 491
    }
}

enum SdpCodecs {
    /**
     * The web calling SDK's reorderCodecsInSdp: move the preferred codecs to
     * the front of each m=audio format list, keeping everything else (and every
     * a=rtpmap line) where it was. The SBC takes the first one it can do.
     */
    static func prefer(_ sdp: String, _ preferred: [String] = ["opus", "PCMU"]) -> String {
        let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
        let lines = sdp.components(separatedBy: separator)
        var names: [String: String] = [:]
        for line in lines where line.hasPrefix("a=rtpmap:") {
            let body = line.dropFirst("a=rtpmap:".count)
            let parts = body.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            names[String(parts[0])] = parts[1].split(separator: "/").first.map { $0.lowercased() } ?? ""
        }
        let wanted = preferred.map { $0.lowercased() }
        return lines.map { line -> String in
            guard line.hasPrefix("m=audio") else { return line }
            let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return line }
            let formats = Array(parts[3...])
            let ranked = formats.enumerated().sorted { a, b in
                let ra = wanted.firstIndex(of: names[a.element] ?? "") ?? 999
                let rb = wanted.firstIndex(of: names[b.element] ?? "") ?? 999
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map { $0.element }
            return (Array(parts[0..<3]) + ranked).joined(separator: " ")
        }.joined(separator: separator)
    }
}

/// One ICE server from the mint, as WebRTC takes it.
struct RtcIceServer: Equatable {
    var urls: [String]
    var username: String?
    var credential: String?
}
