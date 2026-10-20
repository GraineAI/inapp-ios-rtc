import Foundation
import Testing
@testable import GraineInAppRTC

/*
 * THE USER AGENT AGAINST A FAKE SBC — over a real WebSocket on this machine
 * (the same URLSession socket an app uses), the server scripted the way
 * production's answers (TRACE.md): every new request challenged with a 401,
 * a 100 Trying before the INVITE's 401, a 200 whose Contact is a TCP address.
 * Then the timers, on a clock the test moves.
 */

/// The user agent's events, from its queue, read by the test.
final class UaLog {
    private let lock = NSLock()
    private var items: [SipUserAgent.Event] = []

    func add(_ event: SipUserAgent.Event) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }

    var events: [SipUserAgent.Event] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var names: [String] {
        events.map { event in
            switch event {
            case .connected: return "connected"
            case .registered: return "registered"
            case .registrationFailed(let f): return "registrationFailed(\(f.code.map(String.init) ?? f.cause))"
            case .transportLost: return "transportLost"
            case .inviteSent: return "inviteSent"
            case .heard(let code): return "heard(\(code))"
            case .challenged(let code): return "challenged(\(code))"
            case .answered: return "answered"
            case .inviteFailed(let f): return "inviteFailed(\(f.code.map(String.init) ?? f.cause))"
            case .byeReceived: return "byeReceived"
            case .offerReceived: return "offerReceived"
            case .offerRequested: return "offerRequested"
            case .answerInAck: return "answerInAck"
            case .dialogLost(let why): return "dialogLost(\(why))"
            }
        }
    }

    func has(_ name: String) -> Bool { names.contains(name) }
}

/// A user agent, a fake SBC, and what passed between them.
final class UaHarness {
    let server: LocalSipServer
    let clock = DispatchRtcClock()
    let log = UaLog()
    let ua: SipUserAgent
    /// What the fake SBC answers with on its own (production's shapes); a test overrides `script`.
    var script: ((SipMessage, @escaping (String) -> Void) -> Bool)?
    private var nonce = 0
    private let lock = NSLock()

    static let password = "pw"

    init(inviteFinal: Int = 200, challengeCode: Int = 401) throws {
        server = try LocalSipServer()
        let identity = SipIdentity(
            username: "web-0123", realm: "sbc.example.test", password: Self.password, viaHost: "cdh6l13lka9h.invalid",
            contactUser: "e7q9tikf", instanceId: "c30c2118-f5c4-4dd6-898c-3d8485be8150", userAgent: "jambonz-webrtc-0.1.4 graine-inapp-ios/test"
        )
        let log = self.log
        ua = SipUserAgent(server: server.url, identity: identity, clock: clock, sockets: URLSessionRtcSocketFactory(), random: CountingRandom(), onEvent: { log.add($0) })
        server.handle = { [weak self] message, reply in
            guard let self = self else { return }
            if let script = self.script, script(message, reply) { return }
            self.answer(message, reply, inviteFinal: inviteFinal, challengeCode: challengeCode)
        }
    }

    deinit {
        server.stop()
    }

    func nextNonce() -> String {
        lock.lock()
        defer { lock.unlock() }
        nonce += 1
        return "nonce-\(nonce)"
    }

    /// Production's SBC, as the trace shows it.
    func answer(_ m: SipMessage, _ reply: @escaping (String) -> Void, inviteFinal: Int, challengeCode: Int) {
        let header = challengeCode == 407 ? "Proxy-Authenticate" : "WWW-Authenticate"
        let credentials = challengeCode == 407 ? "Proxy-Authorization" : "Authorization"
        let challenge = "\(header): Digest realm=\"sbc.example.test\", algorithm=MD5, qop=\"auth\", nonce=\"\(nextNonce())\""
        switch m.method ?? "" {
        case "REGISTER":
            if m.header(credentials) == nil {
                reply(ScriptedSbc.reply(m, challengeCode, toTag: "7XZFBD4cK46Dr", extra: [challenge]))
            } else {
                reply(ScriptedSbc.reply(m, 200, toTag: "86r8c8mggDX0K", extra: ["Contact: \(m.headerValues("Contact").first ?? "")", "Expires: \(m.header("Expires") ?? "0")"]))
            }
        case "INVITE":
            if m.toTag != nil { return }
            reply(ScriptedSbc.reply(m, 100))
            if m.header(credentials) == nil {
                reply(ScriptedSbc.reply(m, challengeCode, toTag: "aSBtgypQaZ95a", extra: [challenge]))
            } else if inviteFinal == 200 {
                reply(ScriptedSbc.reply(m, 200, toTag: "cByBmmry4gpBj", extra: ["Contact: <sip:198.51.100.7:5060;transport=tcp>", "Content-Type: application/sdp", "X-Call-Sid: 208fd2fd"], body: TraceSdp.answer))
            } else if inviteFinal > 0 {
                reply(ScriptedSbc.reply(m, inviteFinal, toTag: "fail1"))
            }
        case "BYE", "UPDATE":
            reply(ScriptedSbc.reply(m, 200))
        default:
            break
        }
    }

    func run(_ block: @escaping (SipUserAgent) -> Void) {
        clock.run { [ua] in block(ua) }
    }

    /// The digest the SBC would compute for `m`, to check the client's.
    static func expectedResponse(for m: SipMessage, header: String = "Authorization") -> (sent: String?, expected: String?) {
        guard let raw = m.header(header) else { return (nil, nil) }
        func field(_ name: String) -> String? {
            SipParams.splitOutsideQuotes(String(raw.dropFirst("Digest ".count)), on: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(name + "=") }
                .map { SipParams.unquote(String($0.dropFirst(name.count + 1))) }
        }
        guard let username = field("username"), let realm = field("realm"), let nonce = field("nonce"), let uri = field("uri"),
              let cnonce = field("cnonce"), let nc = field("nc"), let qop = field("qop") else { return (field("response"), nil) }
        let ha1 = SipDigest.md5Hex("\(username):\(realm):\(password)")
        let ha2 = SipDigest.md5Hex("\(m.method ?? ""):\(uri)")
        return (field("response"), SipDigest.md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):\(qop):\(ha2)"))
    }
}

@Suite(.serialized) struct SipUserAgentOverWebSocketTests {
    @Test func registersAnsweringTheChallenge() async throws {
        let h = try UaHarness()
        h.run { $0.start() }
        #expect(await eventually { h.log.has("registered") })
        let registers = h.server.receivedMessages.filter { $0.method == "REGISTER" }
        try #require(registers.count == 2)
        #expect(h.server.protocolsAsked.contains("sip"), "the SIP subprotocol")
        #expect(registers[0].header("Authorization") == nil)
        #expect(registers[0].cseq?.number == 1)
        #expect(registers[1].cseq?.number == 2, "CSeq + 1")
        #expect(registers[1].topViaBranch != registers[0].topViaBranch, "a new branch")
        #expect(registers[1].callId == registers[0].callId)
        #expect(registers[1].fromTag == registers[0].fromTag, "the same request, with credentials")
        let digest = UaHarness.expectedResponse(for: registers[1])
        #expect(digest.sent != nil && digest.sent == digest.expected, "a digest the SBC accepts")
        #expect(registers[1].header("Authorization")?.hasPrefix("Digest algorithm=MD5, username=\"web-0123\", realm=\"sbc.example.test\", nonce=\"nonce-1\", uri=\"sip:sbc.example.test\", response=\"") == true)
        #expect(registers[1].header("Authorization")?.contains("qop=auth, cnonce=\"") == true)
        #expect(registers[1].header("Authorization")?.hasSuffix("nc=00000001") == true)
        #expect(registers[0].header("Expires") == "300")
        h.run { $0.close() }
    }

    @Test func dialsAnswersTheInvitesChallengeAndAcksTheAnswer() async throws {
        let h = try UaHarness()
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        let target = "sip:app-817361cd@sbc.example.test"
        h.run { $0.invite(target: target, headers: ["X-Graine-Session-Id: s1", "X-Graine-Agent-Id: agent-1", "X-Application-Sid: 817361cd"], sdp: TraceSdp.offer) }
        try #require(await eventually { h.log.has("answered") })
        #expect(await eventually { h.server.receivedMessages.filter { $0.method == "ACK" }.count == 2 })
        let sent = h.server.receivedMessages.filter { $0.method != "REGISTER" }
        try #require(sent.count >= 4)
        let (first, challengeAck, second, answerAck) = (sent[0], sent[1], sent[2], sent[3])
        #expect(first.method == "INVITE" && first.header("Authorization") == nil)
        #expect(first.cseq?.number == 367)
        #expect(first.headerValues("X-Graine-Agent-Id") == ["agent-1"])
        #expect(first.header("Session-Expires") == "90")
        #expect(first.header("Supported") == "timer,ice,replaces,outbound")
        // The 401 is ACKed on the INVITE's own branch, with the 401's To.
        #expect(challengeAck.method == "ACK")
        #expect(challengeAck.requestUri == target)
        #expect(challengeAck.topViaBranch == first.topViaBranch)
        #expect(challengeAck.cseq?.number == 367 && challengeAck.cseq?.method == "ACK")
        #expect(challengeAck.toTag == "aSBtgypQaZ95a")
        // The INVITE again: CSeq + 1, a new branch, the same Call-ID, From tag and SDP, with credentials.
        #expect(second.method == "INVITE")
        #expect(second.cseq?.number == 368)
        #expect(second.topViaBranch != first.topViaBranch)
        #expect(second.callId == first.callId)
        #expect(second.fromTag == first.fromTag)
        #expect(second.body == first.body, "byte for byte the same offer")
        let digest = UaHarness.expectedResponse(for: second)
        #expect(digest.sent != nil && digest.sent == digest.expected)
        #expect(second.header("Authorization")?.contains("uri=\"\(target)\"") == true)
        // The 200 is ACKed to its Contact, over this socket, with no Route.
        #expect(answerAck.method == "ACK")
        #expect(answerAck.requestUri == "sip:198.51.100.7:5060;transport=tcp")
        #expect(answerAck.cseq?.number == 368)
        #expect(answerAck.toTag == "cByBmmry4gpBj")
        #expect(answerAck.topViaBranch != second.topViaBranch, "a new branch")
        #expect(!answerAck.has("Route"))
        // The challenge is said and is not heard; the INVITE with credentials' own 100 Trying is — the answer follows it.
        #expect(h.log.names.prefix(8) == ["connected", "registered", "inviteSent", "heard(100)", "challenged(401)", "inviteSent", "heard(100)", "answered"])
        h.run { $0.close() }
    }

    @Test func a407IsAnsweredWithProxyAuthorization() async throws {
        let h = try UaHarness(challengeCode: 407)
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.run { $0.invite(target: "sip:app-1@sbc.example.test", headers: [], sdp: TraceSdp.offer) }
        try #require(await eventually { h.log.has("answered") })
        let invites = h.server.receivedMessages.filter { $0.method == "INVITE" }
        #expect(invites.count == 2)
        let digest = UaHarness.expectedResponse(for: invites[1], header: "Proxy-Authorization")
        #expect(digest.sent != nil && digest.sent == digest.expected)
        #expect(invites[1].header("Authorization") == nil)
        h.run { $0.close() }
    }

    @Test func aSecondChallengeIsARefusal() async throws {
        let h = try UaHarness()
        h.script = { m, reply in
            // Credentials refused: challenged again.
            guard m.method == "INVITE" else { return false }
            reply(ScriptedSbc.reply(m, 100))
            reply(ScriptedSbc.reply(m, 401, toTag: "c\(m.cseq!.number)", extra: ["WWW-Authenticate: Digest realm=\"sbc.example.test\", nonce=\"again\", qop=\"auth\""]))
            return true
        }
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.run { $0.invite(target: "sip:app-1@sbc.example.test", headers: [], sdp: "v=0\r\n") }
        #expect(await eventually { h.log.has("inviteFailed(401)") })
        #expect(h.server.receivedMessages.filter { $0.method == "INVITE" }.count == 2, "answered once, never again")
        h.run { $0.close() }
    }

    @Test func theirByeIsAnsweredAndEndsTheCall() async throws {
        let h = try UaHarness()
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.run { $0.invite(target: "sip:app-1@sbc.example.test", headers: [], sdp: TraceSdp.offer) }
        try #require(await eventually { h.log.has("answered") })
        let invite = try #require(h.server.receivedMessages.last { $0.method == "INVITE" })
        h.server.push([
            "BYE sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws SIP/2.0",
            "Via: SIP/2.0/WSS 198.51.100.7:8443;branch=z9hG4bKsbcbye",
            "From: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj",
            "To: \(invite.header("From")!)",
            "Call-ID: \(invite.callId!)",
            "CSeq: 1 BYE",
            "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
        #expect(await eventually { h.log.has("byeReceived") })
        #expect(await eventually { h.server.received.contains { $0.hasPrefix("SIP/2.0 200 OK") && $0.contains("CSeq: 1 BYE") } })
        h.run { $0.hangUp() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!h.server.receivedMessages.contains { $0.method == "BYE" }, "no BYE for a call already over")
        h.run { $0.close() }
    }

    @Test func ourByeGoesToTheContactWithTheNextCSeq() async throws {
        let h = try UaHarness()
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.run { $0.invite(target: "sip:app-1@sbc.example.test", headers: [], sdp: TraceSdp.offer) }
        try #require(await eventually { h.log.has("answered") })
        h.run { $0.hangUp() }
        try #require(await eventually { h.server.receivedMessages.contains { $0.method == "BYE" } })
        let bye = try #require(h.server.receivedMessages.first { $0.method == "BYE" })
        #expect(bye.requestUri == "sip:198.51.100.7:5060;transport=tcp")
        #expect(bye.cseq?.number == 369)
        #expect(bye.toTag == "cByBmmry4gpBj")
        #expect(!bye.has("Route"))
        h.run { $0.close() }
    }

    @Test func hangUpBeforeAnyReplyCancelsOnceTheTryingArrives() async throws {
        let h = try UaHarness()
        let hold = HoldGate()
        h.script = { m, reply in
            guard m.method == "INVITE" else { return false }
            if m.toTag != nil { return true }
            hold.later { reply(ScriptedSbc.reply(m, 100)) }
            return true
        }
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.run { $0.invite(target: "sip:app-1@sbc.example.test", headers: [], sdp: "v=0\r\n") }
        try #require(await eventually { h.server.receivedMessages.contains { $0.method == "INVITE" } })
        h.run { $0.hangUp() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!h.server.receivedMessages.contains { $0.method == "CANCEL" }, "a CANCEL waits for proof the INVITE arrived")
        hold.release()
        try #require(await eventually { h.server.receivedMessages.contains { $0.method == "CANCEL" } })
        let invite = try #require(h.server.receivedMessages.first { $0.method == "INVITE" })
        let cancel = try #require(h.server.receivedMessages.first { $0.method == "CANCEL" })
        #expect(cancel.topViaBranch == invite.topViaBranch)
        #expect(cancel.cseq?.number == invite.cseq?.number && cancel.cseq?.method == "CANCEL")
        #expect(cancel.toTag == nil)
        // The SBC then ends the INVITE with 487: ACKed, and nobody is told anything more.
        h.server.push(ScriptedSbc.reply(invite, 487, toTag: "t487"))
        #expect(await eventually { h.server.receivedMessages.contains { $0.method == "ACK" } })
        #expect(!h.log.names.contains { $0.hasPrefix("inviteFailed") }, "we hung up: no failure to report")
        h.run { $0.close() }
    }

    @Test func anAnswerThatArrivesAfterOurCancelIsAckedThenEnded() async throws {
        let h = try UaHarness()
        h.script = { m, reply in
            guard m.method == "INVITE", m.toTag == nil else { return false }
            reply(ScriptedSbc.reply(m, 100))
            return true
        }
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.run { $0.invite(target: "sip:app-1@sbc.example.test", headers: [], sdp: "v=0\r\n") }
        try #require(await eventually { h.log.has("heard(100)") })
        h.run { $0.hangUp() }
        try #require(await eventually { h.server.receivedMessages.contains { $0.method == "CANCEL" } })
        let invite = try #require(h.server.receivedMessages.first { $0.method == "INVITE" })
        h.server.push(ScriptedSbc.reply(invite, 200, toTag: "late", extra: ["Contact: <sip:198.51.100.7:5060;transport=tcp>", "Content-Type: application/sdp"], body: TraceSdp.answer))
        #expect(await eventually { h.server.receivedMessages.contains { $0.method == "BYE" } })
        let ack = h.server.receivedMessages.first { $0.method == "ACK" }
        let bye = h.server.receivedMessages.first { $0.method == "BYE" }
        #expect(ack?.toTag == "late" && bye?.toTag == "late")
        #expect(!h.log.has("answered"), "nobody is told about a call we no longer want")
        h.run { $0.close() }
    }

    @Test func aReInviteFromTheSbcIsAnsweredFromTheMedia() async throws {
        let h = try UaHarness()
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.run { $0.invite(target: "sip:app-1@sbc.example.test", headers: [], sdp: TraceSdp.offer) }
        try #require(await eventually { h.log.has("answered") })
        let invite = try #require(h.server.receivedMessages.last { $0.method == "INVITE" })
        h.server.push([
            "INVITE sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws SIP/2.0",
            "Via: SIP/2.0/WSS 198.51.100.7:8443;branch=z9hG4bKreinv",
            "From: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj",
            "To: \(invite.header("From")!)",
            "Call-ID: \(invite.callId!)",
            "CSeq: 2 INVITE",
            "Contact: <sip:198.51.100.7:5060;transport=tcp>",
            "Session-Expires: 90;refresher=uas",
            "Content-Type: application/sdp",
            "Content-Length: \(TraceSdp.answer.utf8.count)", "", TraceSdp.answer,
        ].joined(separator: "\r\n"))
        try #require(await eventually { h.log.has("offerReceived") })
        guard case let .offerReceived(sdp, reply)? = h.log.events.last(where: { if case .offerReceived = $0 { return true }; return false }) else {
            Issue.record("no offer")
            return
        }
        #expect(sdp == TraceSdp.answer)
        reply(.success("v=0\r\no=- refreshed\r\n"))
        try #require(await eventually { h.server.received.contains { $0.hasPrefix("SIP/2.0 200 OK") && $0.contains("CSeq: 2 INVITE") } })
        let ok = try #require(h.server.received.first { $0.hasPrefix("SIP/2.0 200 OK") && $0.contains("CSeq: 2 INVITE") })
        #expect(ok.contains("Contact: <sip:e7q9tikf@cdh6l13lka9h.invalid;transport=ws;ob>"))
        #expect(ok.contains("Session-Expires: 90;refresher=uas"))
        #expect(ok.contains("Content-Type: application/sdp"))
        #expect(ok.hasSuffix("v=0\r\no=- refreshed\r\n"))
        h.run { $0.close() }
    }

    @Test func garbageIsDroppedAndTheAgentKeepsWorking() async throws {
        let h = try UaHarness()
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.server.push("this is not SIP")
        h.server.push("SIP/2.0 200 OK\r\nVia: broken")
        h.server.push(String(repeating: "\u{0}", count: 100))
        h.server.push("\r\n\r\n")
        h.server.push("OPTIONS sip:e7q9tikf@cdh6l13lka9h.invalid SIP/2.0\r\nVia: SIP/2.0/WSS 198.51.100.7;branch=z9hG4bKopt\r\nFrom: <sip:sbc@sbc.example.test>;tag=o1\r\nTo: <sip:web-0123@sbc.example.test>\r\nCall-ID: o1\r\nCSeq: 1 OPTIONS\r\nContent-Length: 0\r\n\r\n")
        #expect(await eventually { h.server.received.contains { $0.hasPrefix("SIP/2.0 200 OK") && $0.contains("CSeq: 1 OPTIONS") } })
        h.server.push("FROB sip:e7q9tikf@cdh6l13lka9h.invalid SIP/2.0\r\nVia: SIP/2.0/WSS 198.51.100.7;branch=z9hG4bKfrob\r\nFrom: <sip:sbc@sbc.example.test>;tag=o2\r\nTo: <sip:web-0123@sbc.example.test>\r\nCall-ID: o2\r\nCSeq: 1 FROB\r\nContent-Length: 0\r\n\r\n")
        #expect(await eventually { h.server.received.contains { $0.hasPrefix("SIP/2.0 501 Not Implemented") } })
        h.server.push("BYE sip:e7q9tikf@cdh6l13lka9h.invalid SIP/2.0\r\nVia: SIP/2.0/WSS 198.51.100.7;branch=z9hG4bKbye\r\nFrom: <sip:sbc@sbc.example.test>;tag=o3\r\nTo: <sip:web-0123@sbc.example.test>;tag=nobody\r\nCall-ID: o3\r\nCSeq: 1 BYE\r\nContent-Length: 0\r\n\r\n")
        #expect(await eventually { h.server.received.contains { $0.hasPrefix("SIP/2.0 481") } }, "a BYE for no call")
        h.run { $0.close() }
    }

    @Test func shutDownWithdrawsTheRegistrationThenCloses() async throws {
        let h = try UaHarness()
        h.run { $0.start() }
        try #require(await eventually { h.log.has("registered") })
        h.run { $0.shutDown() }
        #expect(await eventually { h.server.receivedMessages.filter { $0.method == "REGISTER" }.count == 4 })
        let registers = h.server.receivedMessages.filter { $0.method == "REGISTER" }
        #expect(registers[2].header("Expires") == "0")
        #expect(registers[2].headerValues("Contact").first?.hasSuffix(";expires=0") == true)
        #expect(registers[2].callId == registers[0].callId, "the registration's Call-ID")
        #expect(registers[2].fromTag != registers[0].fromTag, "a new From tag")
        #expect(registers[2].cseq?.number == 3)
        #expect(registers[3].cseq?.number == 4, "challenged too, and answered")
        #expect(await eventually { !h.server.closes.isEmpty }, "then the socket is closed")
    }
}

/// Hold a reply until the test lets it go.
final class HoldGate {
    private let lock = NSLock()
    private var held: [() -> Void] = []
    private var open = false

    func later(_ block: @escaping () -> Void) {
        lock.lock()
        if open {
            lock.unlock()
            block()
            return
        }
        held.append(block)
        lock.unlock()
    }

    func release() {
        lock.lock()
        open = true
        let waiting = held
        held = []
        lock.unlock()
        waiting.forEach { $0() }
    }
}

// MARK: - The timers, on a clock the test moves

@Suite struct SipUserAgentTimerTests {
    private struct Rig {
        let clock = ManualRtcClock()
        let sockets = MemorySocketFactory()
        let sbc = ScriptedSbc()
        let log = UaLog()
        let ua: SipUserAgent

        init() {
            let identity = SipIdentity(username: "web-1", realm: "sbc.example.test", password: "pw", viaHost: "v.invalid", contactUser: "c1", instanceId: "i", userAgent: "ua")
            let log = self.log
            ua = SipUserAgent(server: URL(string: "wss://sbc.example.test:8443")!, identity: identity, clock: clock, sockets: sockets, random: CountingRandom(), onEvent: { log.add($0) })
            let sbc = self.sbc
            sockets.onOpen = { sbc.attach($0) }
        }

        func connectAndAnswer() {
            ua.start()
            sockets.sip.last?.open()
            ua.invite(target: "sip:app-1@sbc.example.test", headers: [], sdp: "v=0\r\n")
        }
    }

    @Test func theSessionIsRefreshedEvery45SecondsWithAnUpdate() {
        let rig = Rig()
        rig.connectAndAnswer()
        #expect(rig.log.has("answered"))
        rig.clock.advance(44.9)
        #expect(!rig.sbc.received.contains { $0.method == "UPDATE" })
        rig.clock.advance(0.2)
        let updates = rig.sbc.received.filter { $0.method == "UPDATE" }
        #expect(updates.count == 1)
        #expect(updates.first?.header("Session-Expires") == "90;refresher=uac")
        #expect(updates.first?.body == "")
        #expect(updates.first?.cseq?.number == 369, "one after the INVITE")
        #expect(updates.first?.requestUri == "sip:198.51.100.7:5060;transport=tcp")
        rig.clock.advance(45)
        #expect(rig.sbc.received.filter { $0.method == "UPDATE" }.count == 2, "re-armed by the 200")
    }

    @Test func whenTheSbcRefreshesNoUpdateIsSentAndSilenceEndsTheSession() {
        let rig = Rig()
        rig.sbc.inviteFinal = nil
        rig.connectAndAnswer()
        let invite = rig.sbc.received.last { $0.method == "INVITE" }!
        rig.sockets.sip.last?.deliver(ScriptedSbc.reply(invite, 200, toTag: "t1", extra: ["Contact: <sip:198.51.100.7:5060;transport=tcp>", "Session-Expires: 120;refresher=uas", "Content-Type: application/sdp"], body: TraceSdp.answer))
        #expect(rig.log.has("answered"))
        rig.clock.advance(131)
        #expect(!rig.sbc.received.contains { $0.method == "UPDATE" }, "the SBC refreshes, not us")
        rig.clock.advance(2)
        #expect(rig.sbc.received.contains { $0.method == "BYE" })
        #expect(rig.log.names.contains("dialogLost(session timer expired)"))
    }

    @Test func anInviteNobodyAnswersTimesOut() {
        let rig = Rig()
        rig.sbc.sendTrying = false
        rig.sbc.challenge = false
        rig.sbc.inviteFinal = nil
        rig.connectAndAnswer()
        rig.clock.advance(31.9)
        #expect(!rig.log.names.contains { $0.hasPrefix("inviteFailed") })
        rig.clock.advance(0.2)
        #expect(rig.log.names.contains("inviteFailed(Request Timeout)"))
    }

    @Test func theRegistrationIsRefreshedBeforeItLapses() {
        let rig = Rig()
        rig.ua.start()
        rig.sockets.sip.last?.open()
        #expect(rig.log.has("registered"))
        let before = rig.sbc.received.filter { $0.method == "REGISTER" }.count
        rig.clock.advance(149)
        #expect(rig.sbc.received.filter { $0.method == "REGISTER" }.count == before)
        rig.clock.advance(120)
        #expect(rig.sbc.received.filter { $0.method == "REGISTER" }.count == before + 2, "refreshed (and challenged again) inside 150–268 s")
    }

    @Test func aLiveCallsLostSocketIsReconnectedAndReRegistered() {
        let rig = Rig()
        rig.connectAndAnswer()
        rig.ua.keepsTransport = true
        rig.sockets.sip.last?.serverClose(1006, "gone")
        #expect(rig.log.has("transportLost"))
        rig.clock.advance(1.9)
        #expect(rig.sockets.sip.count == 1)
        rig.clock.advance(0.2)
        #expect(rig.sockets.sip.count == 2, "a new socket after 2 s")
        rig.sockets.sip.last?.open()
        #expect(rig.sockets.sip.last?.sentMessages.first?.method == "REGISTER")
        #expect(!rig.log.names.contains("byeReceived"))
    }

    @Test func aChallengeIsNeverHeardTheInviteWithCredentialsOwnTryingIs() {
        // This SBC answers inside the send, so "inviteSent" is told after the replies here: the replies' order is the point.
        let rig = Rig()
        rig.connectAndAnswer()                             // 100 and 401, then 100 and 200 to the INVITE with credentials
        #expect(rig.log.names.filter { $0 != "inviteSent" } == ["connected", "registered", "heard(100)", "challenged(401)", "heard(100)", "answered"])
        #expect(rig.log.names.filter { $0 == "inviteSent" }.count == 2)

        let bare = Rig()
        bare.sbc.sendTrying = false                        // the challenge with no 100 Trying before it
        bare.sbc.inviteFinal = nil
        bare.connectAndAnswer()
        #expect(bare.log.has("challenged(401)"))
        #expect(!bare.log.names.contains { $0.hasPrefix("heard") }, "a challenge counted as a reply")
        let second = bare.sbc.received.last { $0.method == "INVITE" }!
        bare.sockets.sip.last?.deliver(ScriptedSbc.reply(second, 100))
        #expect(bare.log.names.last == "heard(100)")
    }

    @Test func aShutDownDialKeepsItsSocketUntilItsInviteHasItsFinalAnswer() {
        let rig = Rig()
        rig.sbc.inviteFinal = nil                          // 100 Trying, then nothing
        rig.connectAndAnswer()
        let invite = rig.sbc.received.last { $0.method == "INVITE" }!
        let socket = rig.sockets.sip.last!
        rig.ua.hangUp()
        rig.ua.shutDown()
        #expect(socket.sentMessages.filter { $0.method == "CANCEL" }.map(\.topViaBranch) == [invite.topViaBranch])
        #expect(socket.sentMessages.last { $0.method == "REGISTER" }?.header("Expires") == "0", "the registration goes at once")
        rig.clock.advance(3)
        #expect(!socket.closedByClient, "the socket the dial's ending travels on went before it")
        socket.deliver(ScriptedSbc.reply(invite, 487, toTag: "t487"))
        #expect(socket.sentMessages.last?.method == "ACK", "the 487 is ACKed")
        rig.clock.advance(0.1)
        #expect(socket.closedByClient, "then the socket goes")
    }

    @Test func aShutDownDialAnsweredAcrossItsCancelIsAckedAndEndedBeforeTheSocketGoes() {
        let rig = Rig()
        rig.sbc.inviteFinal = nil
        rig.connectAndAnswer()
        let invite = rig.sbc.received.last { $0.method == "INVITE" }!
        let socket = rig.sockets.sip.last!
        rig.ua.hangUp()
        rig.ua.shutDown()
        rig.clock.advance(1)
        socket.deliver(ScriptedSbc.answer(invite))         // crossing the CANCEL: the leg exists now
        #expect(socket.sentMessages.suffix(2).map { $0.method ?? "reply" } == ["ACK", "BYE"])
        #expect(socket.sentMessages.last?.requestUri == "sip:198.51.100.7:5060;transport=tcp")
        rig.clock.advance(0.1)
        #expect(socket.closedByClient, "the BYE answered, the socket goes")
        #expect(!rig.log.has("answered"), "nobody is told about a call we let go")
    }

    @Test func aShutDownDialThatNeverHearsBackLetsItsSocketGoAfterTheGrace() {
        let rig = Rig()
        rig.sbc.inviteFinal = nil
        rig.connectAndAnswer()
        let socket = rig.sockets.sip.last!
        rig.ua.hangUp()
        rig.ua.shutDown(grace: 0.5)                        // a dial in flight holds it for its own grace, whatever is asked
        rig.clock.advance(DialRules.abandonedDialGrace - 0.1)
        #expect(!socket.closedByClient)
        rig.clock.advance(0.2)
        #expect(socket.closedByClient)
    }

    @Test func aShutDownWithNoDialClosesOnceTheRegistrationIsWithdrawn() {
        let rig = Rig()
        rig.ua.start()
        rig.sockets.sip.last?.open()
        #expect(rig.log.has("registered"))
        rig.ua.shutDown()
        rig.clock.advance(0.1)
        #expect(rig.sockets.sip.last?.closedByClient == true, "nothing to wait for: it goes at once")
    }

    @Test func requestsInsideTheDialogAreAnswered() {
        let rig = Rig()
        rig.connectAndAnswer()
        let invite = rig.sbc.received.last { $0.method == "INVITE" }!
        func request(_ method: String, cseq: Int, body: String = "") -> String {
            [
                "\(method) sip:c1@v.invalid SIP/2.0", "Via: SIP/2.0/WSS 198.51.100.7;branch=z9hG4bK\(method)\(cseq)",
                "From: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj", "To: \(invite.header("From")!)",
                "Call-ID: \(invite.callId!)", "CSeq: \(cseq) \(method)", "Content-Length: \(body.utf8.count)", "", body,
            ].joined(separator: "\r\n")
        }
        let socket = rig.sockets.sip.last!
        socket.deliver(request("OPTIONS", cseq: 2))
        socket.deliver(request("INFO", cseq: 3))
        socket.deliver(request("NOTIFY", cseq: 4))
        socket.deliver(request("UPDATE", cseq: 5))
        socket.deliver(request("SUBSCRIBE", cseq: 6))
        socket.deliver(request("OPTIONS", cseq: 1))
        let replies = socket.sent.filter { $0.hasPrefix("SIP/2.0") }
        #expect(replies.count == 6)
        #expect(replies[0].hasPrefix("SIP/2.0 200") && replies[1].hasPrefix("SIP/2.0 200") && replies[2].hasPrefix("SIP/2.0 200"))
        #expect(replies[3].hasPrefix("SIP/2.0 200") && replies[3].contains("Session-Expires: 90;refresher=uas"), "an UPDATE with no body is a refresh")
        #expect(replies[4].hasPrefix("SIP/2.0 405"), "known, not supported")
        #expect(replies[5].hasPrefix("SIP/2.0 500"), "an older CSeq")
    }
}
