import CryptoKit
import Foundation

/*
 * DIGEST AUTHENTICATION (RFC 2617, as RFC 3261 uses it) — the SBC challenges
 * every new transaction (the REGISTER, the INVITE, the un-REGISTER), each with
 * a fresh nonce, and each challenge is answered exactly once. MD5 because that
 * is what the SBC offers; `qop=auth` (or `auth-int`) with a cnonce and nc when
 * it is offered. The header is written in JsSIP's parameter order.
 */

/// What a 401's WWW-Authenticate (or a 407's Proxy-Authenticate) asks for.
struct SipChallenge: Equatable {
    var realm: String
    var nonce: String
    var opaque: String?
    var algorithm: String?
    /// The qop options offered, lower-cased; empty when none.
    var qop: [String]
    var stale: Bool

    /// `Digest realm="…", nonce="…", qop="auth,auth-int", algorithm=MD5, opaque="…", stale=FALSE`.
    static func parse(_ header: String) -> SipChallenge? {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("digest") else { return nil }
        let rest = text.dropFirst("digest".count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var fields: [String: String] = [:]
        for item in SipParams.splitOutsideQuotes(String(rest), on: ",") {
            let pair = item.trimmingCharacters(in: .whitespaces)
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = SipParams.unquote(pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if !name.isEmpty, fields[name] == nil { fields[name] = value }
        }
        guard let realm = fields["realm"], let nonce = fields["nonce"], !nonce.isEmpty else { return nil }
        let qop = (fields["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        return SipChallenge(
            realm: realm,
            nonce: nonce,
            opaque: fields["opaque"],
            algorithm: fields["algorithm"],
            qop: qop,
            stale: fields["stale"]?.lowercased() == "true"
        )
    }
}

enum SipDigest {
    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /**
     * The Authorization (or Proxy-Authorization) value answering `challenge`
     * for one request — or nil when it cannot be answered (an algorithm other
     * than MD5, or a qop that is neither auth nor auth-int), which the caller
     * treats as a refusal. JsSIP prefers auth-int when both are offered.
     */
    static func authorization(
        username: String,
        password: String,
        method: String,
        uri: String,
        body: String = "",
        challenge: SipChallenge,
        cnonce: String,
        nc: Int = 1
    ) -> String? {
        if let algorithm = challenge.algorithm, algorithm.uppercased() != "MD5" { return nil }
        var qop: String?
        if !challenge.qop.isEmpty {
            if challenge.qop.contains("auth-int") {
                qop = "auth-int"
            } else if challenge.qop.contains("auth") {
                qop = "auth"
            } else {
                return nil
            }
        }
        let ncHex = String(format: "%08x", nc)
        let ha1 = md5Hex("\(username):\(challenge.realm):\(password)")
        let response: String
        switch qop {
        case "auth":
            let ha2 = md5Hex("\(method):\(uri)")
            response = md5Hex("\(ha1):\(challenge.nonce):\(ncHex):\(cnonce):auth:\(ha2)")
        case "auth-int":
            let ha2 = md5Hex("\(method):\(uri):\(md5Hex(body))")
            response = md5Hex("\(ha1):\(challenge.nonce):\(ncHex):\(cnonce):auth-int:\(ha2)")
        default:
            let ha2 = md5Hex("\(method):\(uri)")
            response = md5Hex("\(ha1):\(challenge.nonce):\(ha2)")
        }
        var params = [
            "algorithm=MD5",
            "username=\"\(username)\"",
            "realm=\"\(challenge.realm)\"",
            "nonce=\"\(challenge.nonce)\"",
            "uri=\"\(uri)\"",
            "response=\"\(response)\"",
        ]
        if let opaque = challenge.opaque { params.append("opaque=\"\(opaque)\"") }
        if let qop = qop {
            params.append("qop=\(qop)")
            params.append("cnonce=\"\(cnonce)\"")
            params.append("nc=\(ncHex)")
        }
        return "Digest " + params.joined(separator: ", ")
    }
}
