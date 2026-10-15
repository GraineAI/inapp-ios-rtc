import Foundation

/*
 * READING A SIP MESSAGE — hardened, because whatever comes down the socket is
 * untrusted input inside somebody else's app.
 *
 * One WebSocket message is one SIP message (RFC 7118), so there is no stream
 * to resynchronise: a message is read whole or dropped whole. Bounded
 * everywhere — the size, the header count, each line — and read with loops,
 * never recursion. Anything malformed is nil, never a crash; the user agent
 * drops it and carries on, which is what a SIP stack does with garbage.
 *
 * Accepted on the way in, because servers send them: LF-only line ends,
 * folded header lines (RFC 3261 §7.3.1), compact header names ("i" for
 * Call-ID), several values on one Via/Route/Record-Route/Contact line, and a
 * missing Content-Length (the WebSocket frame delimits the body).
 */
enum SipParser {
    /// A call's largest message is an SDP of a few kilobytes; anything near this is not one of ours.
    static let maxBytes = 65_536
    static let maxHeaders = 128
    static let maxLineBytes = 8_192

    /// The compact forms (RFC 3261 §7.3.3 and the extensions that defined one).
    static let compactNames: [String: String] = [
        "i": "Call-ID", "m": "Contact", "f": "From", "t": "To", "v": "Via", "l": "Content-Length",
        "c": "Content-Type", "k": "Supported", "e": "Content-Encoding", "s": "Subject", "o": "Event",
        "u": "Allow-Events", "x": "Session-Expires", "r": "Refer-To", "b": "Referred-By",
        "a": "Accept-Contact", "j": "Reject-Contact", "d": "Request-Disposition", "y": "Identity", "n": "Identity-Info",
    ]

    /// Headers whose values may be listed with commas, split into one entry each.
    static let listHeaders: Set<String> = ["via", "route", "record-route", "contact"]

    static func parse(_ text: String) -> SipMessage? {
        let bytes = Array(text.utf8)
        return parse(bytes: bytes)
    }

    static func parse(_ data: Data) -> SipMessage? {
        parse(bytes: [UInt8](data))
    }

    static func parse(bytes input: [UInt8]) -> SipMessage? {
        guard !input.isEmpty, input.count <= maxBytes else { return nil }
        // A keep-alive (CRLFs, nothing else) is not a message.
        var start = 0
        while start < input.count, input[start] == 13 || input[start] == 10 { start += 1 }
        guard start < input.count else { return nil }

        // The blank line between the headers and the body.
        guard let (headEnd, bodyStart) = blankLine(input, from: start) else { return nil }

        // Lines are cut on the bytes: in a Swift String "\r\n" is ONE character, which no split on "\n" finds.
        var lines: [String] = []
        var lineStart = start
        var at = start
        while at <= headEnd {
            if at == headEnd || input[at] == 10 {
                var end = at
                if end > lineStart, input[end - 1] == 13 { end -= 1 }
                if end - lineStart > maxLineBytes { return nil }
                guard let line = String(bytes: input[lineStart..<end], encoding: .utf8) else { return nil }
                lines.append(line)
                lineStart = at + 1
            }
            at += 1
        }
        guard let first = lines.first, let kind = startLine(first) else { return nil }

        // Unfold, then split names from values.
        var headers: [(name: String, value: String)] = []
        var pending: (name: String, value: String)?
        func flush() -> Bool {
            guard let p = pending else { return true }
            pending = nil
            let key = p.name.lowercased()
            if listHeaders.contains(key) {
                for item in SipParams.splitOutsideQuotes(p.value, on: ",") {
                    let value = item.trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { headers.append((p.name, value)) }
                }
            } else {
                headers.append(p)
            }
            return headers.count <= maxHeaders
        }
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if line.first == " " || line.first == "\t" {
                // A folded continuation: it belongs to the header above it, if there is one.
                guard var p = pending else { return nil }
                p.value += " " + line.trimmingCharacters(in: .whitespaces)
                if p.value.utf8.count > maxLineBytes { return nil }
                pending = p
                continue
            }
            guard flush() else { return nil }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let rawName = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard isToken(rawName) else { return nil }
            let name = compactNames[rawName.lowercased()] ?? rawName
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            pending = (name, value)
        }
        guard flush() else { return nil }

        // The body: exactly Content-Length bytes when it is given, else the rest of the frame.
        var bodyBytes = Array(input[bodyStart...])
        if let rawLength = headers.first(where: { $0.name.lowercased() == "content-length" })?.value {
            guard let length = Int(rawLength), length >= 0, length <= maxBytes, bodyBytes.count >= length else { return nil }
            bodyBytes = Array(bodyBytes.prefix(length))
        }
        guard let body = String(bytes: bodyBytes, encoding: .utf8) else { return nil }

        let message = SipMessage(kind: kind, headers: headers, body: body)
        // What every message must carry for this user agent to act on it.
        guard message.callId?.isEmpty == false, message.cseq != nil,
              message.header("From") != nil, message.header("To") != nil,
              !message.headerValues("Via").isEmpty else { return nil }
        // A request's CSeq names its own method (RFC 3261 §8.1.1.5).
        if let method = message.method, let cseq = message.cseq, method != cseq.method { return nil }
        return message
    }

    /// Where the headers end and the body begins: CRLFCRLF, or LFLF from a lenient sender.
    private static func blankLine(_ b: [UInt8], from: Int) -> (Int, Int)? {
        var i = from
        while i + 1 < b.count {
            if b[i] == 10 {
                if b[i + 1] == 10 { return (i, i + 2) }
                if b[i + 1] == 13, i + 2 < b.count, b[i + 2] == 10 { return (i, i + 3) }
            }
            i += 1
        }
        // Headers with no blank line at all: a message cut short.
        return nil
    }

    private static func startLine(_ line: String) -> SipMessage.Kind? {
        if line.hasPrefix("SIP/2.0 ") {
            let rest = line.dropFirst("SIP/2.0 ".count)
            let codeText = rest.prefix(3)
            guard codeText.count == 3, codeText.allSatisfy({ $0.isASCII && $0.isNumber }), let code = Int(codeText),
                  (100...699).contains(code) else { return nil }
            let after = rest.dropFirst(3)
            guard after.isEmpty || after.first == " " else { return nil }
            return .response(code: code, reason: after.trimmingCharacters(in: .whitespaces))
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2] == "SIP/2.0" else { return nil }
        let method = String(parts[0])
        guard isToken(method), method.allSatisfy({ $0.isASCII && ($0.isUppercase || $0 == "-") }) else { return nil }
        let uri = String(parts[1])
        guard uri.contains(":") else { return nil }
        return .request(method: method, uri: uri)
    }

    /// RFC 3261's `token`: what a header name or method may be made of.
    private static func isToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", ".", "!", "%", "*", "_", "+", "`", "'", "~":
                continue
            default:
                return false
            }
        }
        return true
    }
}
