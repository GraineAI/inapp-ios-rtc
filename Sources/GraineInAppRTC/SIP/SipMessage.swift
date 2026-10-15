import Foundation

/*
 * ONE SIP MESSAGE, AS READ OFF THE CALL'S SIP SOCKET.
 *
 * Only `SipParser` makes these, and only from a message it could read whole:
 * a start line, headers, and exactly the body Content-Length promised. Header
 * names are kept in their full form (a compact "i" is "Call-ID") and a header
 * that carried several comma-separated values (Via, Route, Record-Route,
 * Contact) is one entry per value — the shapes JsSIP hands its own code.
 */

struct SipMessage {
    enum Kind: Equatable {
        case request(method: String, uri: String)
        case response(code: Int, reason: String)
    }

    let kind: Kind
    /// Every header in arrival order: the full name as written here, the value trimmed.
    let headers: [(name: String, value: String)]
    let body: String

    var method: String? {
        if case .request(let method, _) = kind { return method }
        return nil
    }

    var requestUri: String? {
        if case .request(_, let uri) = kind { return uri }
        return nil
    }

    var statusCode: Int? {
        if case .response(let code, _) = kind { return code }
        return nil
    }

    var isRequest: Bool { method != nil }

    /// The first value of a header, whatever case it was written in.
    func header(_ name: String) -> String? {
        let key = name.lowercased()
        return headers.first { $0.name.lowercased() == key }?.value
    }

    /// Every value of a header, in order.
    func headerValues(_ name: String) -> [String] {
        let key = name.lowercased()
        return headers.filter { $0.name.lowercased() == key }.map { $0.value }
    }

    func has(_ name: String) -> Bool { header(name) != nil }

    var callId: String? { header("Call-ID") }

    /// "314159 INVITE" → (314159, "INVITE").
    var cseq: (number: Int, method: String)? {
        guard let raw = header("CSeq") else { return nil }
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 2, let n = Int(parts[0]), n >= 0, n < 1 << 31 else { return nil }
        return (n, String(parts[1]))
    }

    var fromTag: String? { header("From").flatMap { SipNameAddr.parse($0)?.param("tag") } }
    var toTag: String? { header("To").flatMap { SipNameAddr.parse($0)?.param("tag") } }

    /// The branch of the topmost Via: which of our transactions a response answers.
    var topViaBranch: String? {
        headerValues("Via").first.flatMap { SipParams.value("branch", inHeader: $0) }
    }

    /// `Session-Expires: 90;refresher=uac` → (90, "uac"); nil when absent or unreadable.
    var sessionExpires: (seconds: Int, refresher: String?)? {
        guard let raw = header("Session-Expires") else { return nil }
        let head = raw.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard let seconds = Int(head), seconds > 0 else { return nil }
        return (seconds, SipParams.value("refresher", inHeader: raw)?.lowercased())
    }

    /// The body is a session description we can read.
    var hasSdp: Bool {
        guard !body.isEmpty else { return false }
        let type = header("Content-Type")?.lowercased() ?? ""
        return type.isEmpty || type.hasPrefix("application/sdp")
    }
}

/**
 * A From, To or Contact value: `"Name" <sip:user@host;uri-param>;tag=x`, or
 * the bare `sip:user@host;tag=x` (then everything after the first ";" is the
 * header's, as RFC 3261 §20 says).
 */
struct SipNameAddr: Equatable {
    var display: String?
    var uri: String
    /// Header parameters, names lower-cased, in order; a flag parameter has no value.
    var params: [(name: String, value: String?)]

    static func == (a: SipNameAddr, b: SipNameAddr) -> Bool {
        a.display == b.display && a.uri == b.uri && a.params.map { "\($0.name)=\($0.value ?? "")" } == b.params.map { "\($0.name)=\($0.value ?? "")" }
    }

    func param(_ name: String) -> String? {
        let key = name.lowercased()
        guard let hit = params.first(where: { $0.name == key }) else { return nil }
        return hit.value ?? ""
    }

    static func parse(_ raw: String) -> SipNameAddr? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let open = SipParams.indexOutsideQuotes(of: "<", in: text) {
            guard let close = text[open...].firstIndex(of: ">") else { return nil }
            let uri = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            guard !uri.isEmpty else { return nil }
            var display = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            if display.hasPrefix("\""), display.hasSuffix("\""), display.count >= 2 {
                display = String(display.dropFirst().dropLast())
            }
            let rest = String(text[text.index(after: close)...])
            return SipNameAddr(display: display.isEmpty ? nil : display, uri: uri, params: SipParams.list(rest))
        }
        // No angle brackets: the URI runs to the first ";".
        let pieces = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let uri = String(pieces[0]).trimmingCharacters(in: .whitespaces)
        guard !uri.isEmpty, !uri.contains(" ") else { return nil }
        let rest = pieces.count > 1 ? ";" + pieces[1] : ""
        return SipNameAddr(display: nil, uri: uri, params: SipParams.list(rest))
    }
}

/// `;name=value` lists, comma-separated header values and quoted strings — read without recursion.
enum SipParams {
    /// `;a=1;b;c="x;y"` → [(a, 1), (b, nil), (c, x;y)]. Leading text before the first ";" is skipped.
    static func list(_ text: String) -> [(name: String, value: String?)] {
        var out: [(String, String?)] = []
        for piece in splitOutsideQuotes(text, on: ";").dropFirst() {
            let item = piece.trimmingCharacters(in: .whitespaces)
            if item.isEmpty { continue }
            if let eq = item.firstIndex(of: "=") {
                let name = item[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = unquote(item[item.index(after: eq)...].trimmingCharacters(in: .whitespaces))
                if !name.isEmpty { out.append((name, value)) }
            } else {
                out.append((item.lowercased(), nil))
            }
        }
        return out
    }

    /// A parameter of a whole header value (`branch` of a Via, `refresher` of Session-Expires).
    static func value(_ name: String, inHeader header: String) -> String? {
        let key = name.lowercased()
        guard let hit = list(header).first(where: { $0.name == key }) else { return nil }
        return hit.value ?? ""
    }

    /// Split on `separator` where it is not inside "quotes" or <angle brackets>.
    static func splitOutsideQuotes(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var angle = 0
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if quoted && ch == "\\" {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" { quoted.toggle() }
            if !quoted {
                if ch == "<" { angle += 1 }
                if ch == ">" && angle > 0 { angle -= 1 }
                if ch == separator && angle == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    static func indexOutsideQuotes(of target: Character, in text: String) -> String.Index? {
        var quoted = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if escaped {
                escaped = false
            } else if quoted && ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                quoted.toggle()
            } else if !quoted && ch == target {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var out = ""
        var escaped = false
        for ch in text.dropFirst().dropLast() {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
