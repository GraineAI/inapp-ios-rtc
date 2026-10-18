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
     * From the SBC's first reply to the answer. The SBC replies the moment it has the INVITE, and a
     * healthy call is answered right after: 37 ms median on production, measured at the SBC on
     * 18 Oct 2026. One that has said "trying" and then nothing for half a second is stuck — a feature
     * server that took the call and never answered — so it is cancelled and dialled once more on a
     * fresh connection. A seatbelt, and a short one: 0.10.2's 3 s was 80× a normal answer and only
     * delayed the fallback; this is still ~13× the median, so a healthy call never trips it.
     */
    static let answerAfterHeard = 0.5
    /// Answered, and still no media path after this: the customer's patience, not ICE's 30 s.
    static let iceConnectDeadline = 8.0
    /// The REGISTER's bound: success, an explicit refusal, or this.
    static let registerDeadline = 15.0
    /// A credential with less than this left is minted afresh for the second dial.
    static let credentialMinRemaining = 20.0

    /**
     * From the INVITE leaving to ANY reply. The SBC answers 100 Trying the
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
        // A "SIP Failure Code" is the network's only when it is a 5xx or carries no code.
        let networkish = networkCauses.contains(cause) && (cause != SipCauses.sipFailureCode || code == nil || code! >= 500)
        if networkish && dialsSoFar < maxDials { return .redial }
        return .fallback
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
