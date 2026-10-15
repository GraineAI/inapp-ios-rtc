import Foundation

/*
 * WRITING SIP THE WAY THE VOICE BAR WRITES IT.
 *
 * The voice bar's SIP stack is JsSIP 3.13 (through the web calling SDK
 * 0.1.4), and production's SBC has only ever seen its messages. So these are
 * byte-for-byte its shapes, checked against a recorded production trace: the
 * header order (the stack's own headers, then the caller's, then Allow,
 * Supported, User-Agent and Content-Length), the Via host and Contact made up
 * once per user agent under ".invalid", Max-Forwards 69, the Supported list
 * per method. A message the SBC has never seen is a call that might fail in a
 * way nobody has measured; one it sees every day is not.
 */

/// The constants JsSIP writes into every request.
enum SipShape {
    static let maxForwards = 69
    static let allow = "INVITE,ACK,CANCEL,BYE,UPDATE,MESSAGE,OPTIONS,REFER,INFO,NOTIFY,SUBSCRIBE"
    static let accept = "application/sdp, application/dtmf-relay"
    /// The voice bar's SIP client names itself so; ours adds the SDK's own product token.
    static let clientToken = "jambonz-webrtc-0.1.4"
    /// JsSIP's session-timer default: Session-Expires on the INVITE, and the interval when the answer names none.
    static let sessionExpires = 90
    static let minSessionExpires = 60

    static func userAgent(sdkVersion: String) -> String {
        "\(clientToken) graine-inapp-ios/\(sdkVersion)"
    }

    /// Supported, per method, as JsSIP lists it (no GRUU is ever granted here).
    static func supported(for method: String) -> [String] {
        switch method {
        case "REGISTER": return ["path", "gruu", "outbound"]
        case "INVITE": return ["timer", "ice", "replaces", "outbound"]
        case "UPDATE": return ["timer", "ice", "outbound"]
        default: return ["outbound"]
        }
    }

    static let reasons: [Int: String] = [
        100: "Trying", 180: "Ringing", 200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 415: "Unsupported Media Type", 481: "Call/Transaction Does Not Exist",
        486: "Busy Here", 487: "Request Terminated", 488: "Not Acceptable Here", 491: "Request Pending",
        500: "Server Internal Error", 501: "Not Implemented", 603: "Decline",
    ]
}

/// What stays the same for a user agent's whole life: who it is, and the made-up host it writes in Via and Contact.
struct SipIdentity: Equatable {
    var username: String
    var realm: String
    var password: String
    /// `{12 random}.invalid`, in every Via and in the Contact.
    var viaHost: String
    /// The Contact's user part, 8 random characters.
    var contactUser: String
    /// The registration's `+sip.instance` UUID.
    var instanceId: String
    var userAgent: String

    /// `sip:web-…@realm` — From, and To on a REGISTER.
    var aor: String { "sip:\(username)@\(realm)" }
    /// The registrar: the realm without a user.
    var registrar: String { "sip:\(realm)" }
    var contactUri: String { "sip:\(contactUser)@\(viaHost);transport=ws" }
    /// The Contact a dialog uses: with `;ob`, as JsSIP writes it on an INVITE (RFC 5626 outbound).
    var dialogContact: String { "<\(contactUri);ob>" }
}

/// An outgoing request, kept as JsSIP keeps one so it can be cloned and re-sent with credentials.
struct SipRequest {
    var method: String
    var uri: String
    /// The stack's own headers, in the order JsSIP first sets them; a later set replaces in place.
    var headers: [(name: String, values: [String])] = []
    /// The caller's headers, written after the stack's, as given.
    var extra: [String] = []
    var body: String?
    var userAgent: String

    var callId: String { value("Call-ID") ?? "" }
    var cseq: Int { Int((value("CSeq") ?? "").split(separator: " ").first ?? "") ?? 0 }
    var branch: String? { value("Via").flatMap { SipParams.value("branch", inHeader: $0) } }

    func value(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name.lowercased() }?.values.first
    }

    mutating func set(_ name: String, _ values: [String]) {
        if let at = headers.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            headers[at].values = values
        } else {
            headers.append((name, values))
        }
    }

    mutating func set(_ name: String, _ value: String) { set(name, [value]) }

    /// JsSIP's OutgoingRequest.toString().
    var text: String {
        var out = "\(method) \(uri) SIP/2.0\r\n"
        for header in headers {
            for value in header.values { out += "\(header.name): \(value)\r\n" }
        }
        for line in extra { out += line.trimmingCharacters(in: .whitespaces) + "\r\n" }
        out += "Allow: \(SipShape.allow)\r\n"
        out += "Supported: \(SipShape.supported(for: method).joined(separator: ","))\r\n"
        out += "User-Agent: \(userAgent)\r\n"
        if let body = body, !body.isEmpty {
            out += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        } else {
            out += "Content-Length: 0\r\n\r\n"
        }
        return out
    }

    /// A new request in JsSIP's header order: [Route], Via, Max-Forwards, To, From, Call-ID, CSeq.
    static func make(
        method: String,
        uri: String,
        identity: SipIdentity,
        branch: String,
        to: String,
        from: String,
        callId: String,
        cseq: Int,
        route: [String] = [],
        extra: [String] = [],
        body: String? = nil
    ) -> SipRequest {
        var request = SipRequest(method: method, uri: uri, extra: extra, body: body, userAgent: identity.userAgent)
        if !route.isEmpty { request.set("Route", route) }
        request.set("Via", "SIP/2.0/WSS \(identity.viaHost);branch=\(branch)")
        request.set("Max-Forwards", String(SipShape.maxForwards))
        request.set("To", to)
        request.set("From", from)
        request.set("Call-ID", callId)
        request.set("CSeq", "\(cseq) \(method)")
        return request
    }
}

enum SipWriter {
    // MARK: - Registration

    /// REGISTER (expires > 0) or the un-REGISTER (expires 0) — Registrator.register()/unregister().
    static func register(
        identity: SipIdentity,
        callId: String,
        cseq: Int,
        fromTag: String,
        branch: String,
        expires: Int
    ) -> SipRequest {
        let contact = "<\(identity.contactUri)>;+sip.ice;reg-id=1;+sip.instance=\"<urn:uuid:\(identity.instanceId)>\""
        // The two write their headers in opposite orders; the trace has both.
        let extra = expires > 0
            ? ["Expires: \(expires)", "Contact: \(contact);expires=\(expires)"]
            : ["Contact: \(contact);expires=0", "Expires: 0"]
        return SipRequest.make(
            method: "REGISTER", uri: identity.registrar, identity: identity, branch: branch,
            to: "<\(identity.aor)>", from: "<\(identity.aor)>;tag=\(fromTag)",
            callId: callId, cseq: cseq, extra: extra
        )
    }

    // MARK: - The call

    /// The INVITE to the application: the caller's X- headers first, then Contact, Content-Type and Session-Expires.
    static func invite(
        identity: SipIdentity,
        target: String,
        callId: String,
        cseq: Int,
        fromTag: String,
        branch: String,
        headers: [String],
        sdp: String
    ) -> SipRequest {
        SipRequest.make(
            method: "INVITE", uri: target, identity: identity, branch: branch,
            to: "<\(target)>", from: "<\(identity.aor)>;tag=\(fromTag)",
            callId: callId, cseq: cseq,
            extra: headers + ["Contact: \(identity.dialogContact)", "Content-Type: application/sdp", "Session-Expires: \(SipShape.sessionExpires)"],
            body: sdp
        )
    }

    /// The transaction's own ACK for a non-2xx final answer: the INVITE's branch and Request-URI, the answer's To.
    static func ackFailure(invite: SipRequest, responseTo: String) -> SipRequest {
        var ack = SipRequest(method: "ACK", uri: invite.uri, userAgent: invite.userAgent)
        let route = invite.headers.first { $0.name == "Route" }?.values ?? []
        if !route.isEmpty { ack.set("Route", route) }
        ack.set("Via", invite.value("Via") ?? "")
        ack.set("Max-Forwards", String(SipShape.maxForwards))
        ack.set("To", responseTo)
        ack.set("From", invite.value("From") ?? "")
        ack.set("Call-ID", invite.callId)
        ack.set("CSeq", "\(invite.cseq) ACK")
        return ack
    }

    /// CANCEL: the INVITE's branch, Request-URI, From and To (no tag), CSeq number.
    static func cancel(invite: SipRequest) -> SipRequest {
        var cancel = SipRequest(method: "CANCEL", uri: invite.uri, userAgent: invite.userAgent)
        let route = invite.headers.first { $0.name == "Route" }?.values ?? []
        if !route.isEmpty { cancel.set("Route", route) }
        cancel.set("Via", invite.value("Via") ?? "")
        cancel.set("Max-Forwards", String(SipShape.maxForwards))
        cancel.set("To", invite.value("To") ?? "")
        cancel.set("From", invite.value("From") ?? "")
        cancel.set("Call-ID", invite.callId)
        cancel.set("CSeq", "\(invite.cseq) CANCEL")
        return cancel
    }

    /// A request inside the dialog (ACK for the 2xx, BYE, UPDATE, a re-INVITE) — Dialog._createRequest().
    static func inDialog(
        method: String,
        dialog: SipDialog,
        identity: SipIdentity,
        branch: String,
        cseq: Int,
        extra: [String] = [],
        body: String? = nil
    ) -> SipRequest {
        SipRequest.make(
            method: method, uri: dialog.remoteTarget, identity: identity, branch: branch,
            to: "<\(dialog.remoteUri)>;tag=\(dialog.remoteTag)",
            from: "<\(dialog.localUri)>;tag=\(dialog.localTag)",
            callId: dialog.callId, cseq: cseq, route: dialog.routeSet, extra: extra, body: body
        )
    }

    // MARK: - Answering what the SBC sends

    /// IncomingRequest.reply(): the request's Vias, To (with a tag when it had none), From, Call-ID and CSeq back.
    static func response(
        to request: SipMessage,
        code: Int,
        reason: String? = nil,
        extra: [String] = [],
        body: String? = nil,
        newTag: () -> String
    ) -> String {
        let method = request.method ?? ""
        var out = "SIP/2.0 \(code) \(reason ?? SipShape.reasons[code] ?? "")\r\n"
        if method == "INVITE", code > 100, code <= 200 {
            for route in request.headerValues("Record-Route") { out += "Record-Route: \(route)\r\n" }
        }
        for via in request.headerValues("Via") { out += "Via: \(via)\r\n" }
        var to = request.header("To") ?? ""
        if request.toTag == nil, code > 100 { to += ";tag=\(newTag())" }
        out += "To: \(to)\r\n"
        out += "From: \(request.header("From") ?? "")\r\n"
        out += "Call-ID: \(request.callId ?? "")\r\n"
        out += "CSeq: \(request.cseq?.number ?? 0) \(method)\r\n"
        for line in extra { out += line.trimmingCharacters(in: .whitespaces) + "\r\n" }
        var supported: [String] = []
        switch method {
        case "INVITE": supported = ["timer", "ice", "replaces"]
        case "UPDATE": supported = (body?.isEmpty == false) ? ["timer", "ice", "replaces"] : ["timer", "replaces"]
        default: break
        }
        supported.append("outbound")
        if method == "OPTIONS" {
            out += "Allow: \(SipShape.allow)\r\n"
            out += "Accept: \(SipShape.accept)\r\n"
        } else if code == 405 {
            out += "Allow: \(SipShape.allow)\r\n"
        } else if code == 415 {
            out += "Accept: \(SipShape.accept)\r\n"
        }
        out += "Supported: \(supported.joined(separator: ","))\r\n"
        if let body = body, !body.isEmpty {
            out += "Content-Type: application/sdp\r\n"
            out += "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        } else {
            out += "Content-Length: 0\r\n\r\n"
        }
        return out
    }
}

/// An established call's dialog (RFC 3261 §12), from our side as the caller.
struct SipDialog: Equatable {
    var callId: String
    var localTag: String
    var remoteTag: String
    /// Our From URI and theirs (the To), without tags.
    var localUri: String
    var remoteUri: String
    /// Where in-dialog requests go: the 2xx's Contact. Still sent on the same socket — there is only one.
    var remoteTarget: String
    /// The 2xx's Record-Route, reversed. Empty on production's SBC.
    var routeSet: [String]
    /// The last CSeq we used in the dialog; ACK reuses the INVITE's, everything else is one more.
    var localSeq: Int
    var inviteSeq: Int
}
