import Foundation

/*
 * THE CALL'S CREDENTIAL — `POST {baseUrl}/api/embed/rtc-session`, the request
 * the voice bar makes, with the same body the call's ticket would carry
 * (publishable key, the variables, who the customer is) and this call's
 * control-channel session id. The answer is a SIP credential worth one call
 * and a few minutes, the SBC to register with, the application to dial and
 * the ICE servers to reach it through. Every gate (credits, the agent being
 * on, the allowed domains) runs on that request; a refusal sends the call to
 * the WebSocket, which refuses it again in its own words.
 */

struct RtcCredential: Equatable {
    var server: URL
    var username: String
    var password: String
    var realm: String
    var applicationSid: String
    var agentId: String
    var iceServers: [RtcIceServer]
    /// When the credential stops working, by the device's clock; nil when the answer did not say.
    var expiresAt: Date?

    /// Seconds of life left at `now`; infinite when unknown.
    func remaining(at now: Date) -> Double {
        expiresAt.map { $0.timeIntervalSince(now) } ?? .infinity
    }

    /// Read a 200's body. Nil when anything the call needs is missing — that is a failed mint, not a call.
    static func parse(_ data: Data?, now: Date = Date()) -> RtcCredential? {
        guard let data = data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let serverText = text("server"), let server = URL(string: serverText),
              let scheme = server.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              let username = text("username"), let password = text("password"),
              let realm = text("realm"), let application = text("application_sid"),
              // The INVITE's X-Graine-Agent-Id is how the server knows the call is WebRTC: never dial without it.
              let agent = text("agent_id") else { return nil }
        var servers: [RtcIceServer] = []
        for entry in (object["ice_servers"] as? [Any]) ?? [] {
            guard let o = entry as? [String: Any] else { continue }
            var urls: [String] = []
            if let one = o["urls"] as? String { urls = [one] } else if let many = o["urls"] as? [Any] { urls = many.compactMap { $0 as? String } }
            urls = urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !urls.isEmpty else { continue }
            servers.append(RtcIceServer(urls: urls, username: o["username"] as? String, credential: o["credential"] as? String))
        }
        return RtcCredential(
            server: server,
            username: username,
            password: password,
            realm: realm,
            applicationSid: application,
            agentId: agent,
            iceServers: servers,
            expiresAt: text("expires_at").flatMap(Self.date)
        )
    }

    /// An ISO-8601 expiry, with or without fractional seconds (the server writes six digits; the formatter reads three).
    static func date(_ text: String) -> Date? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if let dot = trimmed.firstIndex(of: "."), let zone = trimmed[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = trimmed[trimmed.index(after: dot)..<zone]
            if digits.count > 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
                trimmed.replaceSubrange(trimmed.index(after: dot)..<zone, with: digits.prefix(3))
            }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}

enum RtcMintOutcome: Equatable {
    case credential(RtcCredential)
    /// The server said no (or said something unreadable): its status, its code and its sentence.
    case refused(status: Int, code: String?, message: String?)
    /// It never answered.
    case unreachable(String)

    /// A line for the log and the fallback's detail, with nothing about the customer in it.
    var detail: String {
        switch self {
        case .credential: return "minted"
        case let .refused(status, code, message):
            return "the call session was refused (\(status)\(code.map { " \($0)" } ?? ""))\(message.map { ": \($0)" } ?? "")"
        case .unreachable(let why): return "the call session could not be requested: \(why)"
        }
    }
}

protocol RtcMinting: AnyObject {
    func mint(_ url: URL, body: Data, done: @escaping (RtcMintOutcome) -> Void)
}

final class URLSessionRtcMinting: RtcMinting {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func mint(_ url: URL, body: Data, done: @escaping (RtcMintOutcome) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                done(.unreachable(error.localizedDescription))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done(Self.outcome(status: status, data: data))
        }.resume()
    }

    static func outcome(status: Int, data: Data?) -> RtcMintOutcome {
        if status == 200, let credential = RtcCredential.parse(data) { return .credential(credential) }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let message = (body?["error"] as? String) ?? (body?["detail"] as? String)
        return .refused(status: status, code: body?["code"] as? String, message: message.map { String($0.prefix(160)) })
    }
}
