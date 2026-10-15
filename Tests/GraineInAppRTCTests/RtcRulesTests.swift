import Foundation
import Testing
@_spi(GraineRTC) import GraineInApp
@testable import GraineInAppRTC

/*
 * THE VOICE BAR'S RULES, AS PORTED: when gathering stops, how long a dial is
 * waited for, which failures earn a second dial, how codecs are ordered; then
 * the call session's answer and the control channel's queue and keep-alive.
 */

@Suite struct IceGatheringTests {
    @Test func candidateKinds() {
        #expect(IceGathering.kind("candidate:1 1 udp 2122194688 192.0.2.1 65463 typ host generation 0") == .host)
        #expect(IceGathering.kind("candidate:2 1 udp 1685987072 203.0.113.1 65463 typ srflx raddr 192.0.2.1 rport 65463") == .srflx)
        #expect(IceGathering.kind("candidate:3 1 udp 58598144 203.0.113.9 51750 typ relay raddr 192.0.2.1 rport 65463") == .relay)
        #expect(IceGathering.kind("candidate:4 1 udp 1 192.0.2.1 9 typ prflx") == .prflx)
        #expect(IceGathering.kind("candidate:5 1 udp 1 192.0.2.1 9 typ weird") == .unknown)
        #expect(IceGathering.kind("no type at all") == .unknown)
        #expect(IceGathering.kind(nil) == .end)
        #expect(IceGathering.kind("") == .end)
    }

    /// rtc-ice.ts's endGatheringNow, case by case.
    @Test func whenToStop() {
        #expect(IceGathering.endNow(.relay, elapsed: 0.01, cap: 2.5, wantRelay: true))
        #expect(IceGathering.endNow(.relay, elapsed: 0.01, cap: 1.5, wantRelay: false))
        #expect(IceGathering.endNow(.srflx, elapsed: 0.09, cap: 1.5, wantRelay: false), "a public path, no TURN: enough")
        #expect(!IceGathering.endNow(.srflx, elapsed: 0.09, cap: 2.5, wantRelay: true), "with TURN the relay is worth waiting for")
        #expect(!IceGathering.endNow(.host, elapsed: 1.0, cap: 1.5, wantRelay: false))
        #expect(IceGathering.endNow(.host, elapsed: 1.5, cap: 1.5, wantRelay: false), "the cap")
        #expect(IceGathering.endNow(.end, elapsed: 0, cap: 2.5, wantRelay: true), "nothing more is coming")
        #expect(IceGathering.endNow(.unknown, elapsed: 2.6, cap: 2.5, wantRelay: true))
    }

    @Test func turnDecidesTheCap() {
        let stunOnly = [RtcIceServer(urls: ["stun:stun.example.test:80"], username: nil, credential: nil)]
        let withTurn = stunOnly + [RtcIceServer(urls: [" TURNS:relay.example.test:443?transport=tcp"], username: "u", credential: "c")]
        #expect(!IceGathering.hasTurn(stunOnly))
        #expect(IceGathering.hasTurn(withTurn))
        #expect(IceGathering.cap(for: stunOnly) == 1.5)
        #expect(IceGathering.cap(for: withTurn) == 2.5)
        #expect(IceGathering.cap(for: []) == 1.5)
    }
}

@Suite struct DialRulesTests {
    /// rtc-dial.ts: twice the link's registration time, 3–8 s; 4 s unknown.
    @Test func heardDeadline() {
        #expect(DialRules.heardDeadline(registerSeconds: nil) == 4)
        #expect(DialRules.heardDeadline(registerSeconds: 0) == 4)
        #expect(DialRules.heardDeadline(registerSeconds: .nan) == 4)
        #expect(DialRules.heardDeadline(registerSeconds: 0.356) == 3, "a fast link still gets 3 s")
        #expect(DialRules.heardDeadline(registerSeconds: 2.1) == 4.2)
        #expect(DialRules.heardDeadline(registerSeconds: 9) == 8)
        #expect(DialRules.answerDeadline == 15)
        #expect(DialRules.iceConnectDeadline == 8)
        #expect(DialRules.registerDeadline == 15)
    }

    /// dialFailureVerdict, with JsSIP's words for each SIP status.
    @Test func whichFailuresEarnASecondDial() {
        func verdict(_ code: Int?, _ cause: String? = nil, dials: Int = 1) -> DialVerdict {
            DialRules.verdict(cause: cause ?? SipCauses.forCode(code ?? 0), code: code, dialsSoFar: dials)
        }
        #expect(verdict(nil, "no_response") == .redial)
        #expect(verdict(nil, "no_answer") == .redial)
        #expect(verdict(nil, SipCauses.connectionError) == .redial)
        #expect(verdict(nil, SipCauses.requestTimeout) == .redial)
        #expect(verdict(503) == .redial, "a 5xx is the network's")
        #expect(verdict(408) == .redial, "Unavailable")
        #expect(verdict(480) == .redial)
        #expect(verdict(401) == .redial, "a credential the SBC no longer takes: a fresh mint")
        #expect(verdict(407) == .redial)
        #expect(verdict(403) == .fallback, "a policy: the socket refuses it properly")
        #expect(verdict(404) == .fallback)
        #expect(verdict(486) == .fallback)
        #expect(verdict(488) == .fallback)
        #expect(verdict(400) == .fallback, "a SIP failure code under 500")
        #expect(verdict(nil, "no_response", dials: 2) == .fallback, "one more dial, then the socket")
        #expect(verdict(nil, "Canceled") == .ignore)
        #expect(SipCauses.forCode(603) == SipCauses.rejected)
        #expect(SipCauses.forCode(424) == SipCauses.addressIncomplete)
    }

    @Test func failuresAreDescribedAndReasoned() {
        #expect(RtcCallEngine.describe(cause: "no_response", code: nil) == "no reply to the INVITE")
        #expect(RtcCallEngine.describe(cause: "no_answer", code: nil) == "not answered")
        #expect(RtcCallEngine.describe(cause: SipCauses.rejected, code: 403) == "Rejected 403")
        #expect(RtcCallEngine.reason(cause: "no_response") == .noResponse)
        #expect(RtcCallEngine.reason(cause: "no_answer") == .noAnswer)
        #expect(RtcCallEngine.reason(cause: SipCauses.busy) == .error)
    }
}

@Suite struct SdpCodecTests {
    @Test func opusThenPcmuLeadsTheFormatListAndNothingElseMoves() {
        let reordered = SdpCodecs.prefer(TraceSdp.offer)
        #expect(reordered.contains("m=audio 51750 UDP/TLS/RTP/SAVPF 111 0 63 9 8 13 110 126\r\n"), "the trace's own order")
        let before = TraceSdp.offer.components(separatedBy: "\r\n").filter { !$0.hasPrefix("m=audio") }
        let after = reordered.components(separatedBy: "\r\n").filter { !$0.hasPrefix("m=audio") }
        #expect(before == after, "every other line untouched, rtpmaps in place")
    }

    @Test func pcmuFirstWhenThereIsNoOpus() {
        let sdp = "v=0\nm=audio 9 RTP/AVP 8 0 101\na=rtpmap:8 PCMA/8000\na=rtpmap:0 PCMU/8000\na=rtpmap:101 telephone-event/8000\n"
        #expect(SdpCodecs.prefer(sdp).contains("m=audio 9 RTP/AVP 0 8 101\n"))
        #expect(SdpCodecs.prefer("v=0\r\nm=audio 9 RTP/AVP\r\n") == "v=0\r\nm=audio 9 RTP/AVP\r\n", "too short to touch")
    }
}

@Suite struct MintAnswerTests {
    @Test func readsProductionsAnswer() throws {
        let credential = try #require(RtcCredential.parse(Data(MintFixture.response.utf8)))
        #expect(credential.server.absoluteString == "wss://sbc.example.test:8443")
        #expect(credential.username == "web-0123456789abcdef")
        #expect(credential.realm == "sbc.example.test")
        #expect(credential.applicationSid == "817361cd-2a13-4937-b465-686d3f58eddd")
        #expect(credential.agentId == "agent-webcall-1")
        #expect(credential.iceServers.count == 2)
        #expect(credential.iceServers[1].urls == ["turn:relay.example.test:80", "turns:relay.example.test:443?transport=tcp"])
        #expect(credential.iceServers[1].username == "u")
        let expiry = try #require(credential.expiresAt)
        #expect(abs(expiry.timeIntervalSince1970 - 1_792_023_000.123) < 0.01, "fractional seconds and the offset read")
    }

    @Test func aCredentialMissingAnythingTheCallNeedsIsAFailedMint() {
        for key in ["server", "username", "password", "realm", "application_sid", "agent_id"] {
            var object = try! JSONSerialization.jsonObject(with: Data(MintFixture.response.utf8)) as! [String: Any]
            object.removeValue(forKey: key)
            let data = try! JSONSerialization.data(withJSONObject: object)
            #expect(RtcCredential.parse(data) == nil, "without \(key)")
        }
        #expect(RtcCredential.parse(Data(#"{"server":"https://not-a-socket.example.test"}"#.utf8)) == nil)
        #expect(RtcCredential.parse(nil) == nil)
        #expect(RtcCredential.date("2026-10-15T00:10:00Z")?.timeIntervalSince1970 == 1_792_023_000)
        #expect(RtcCredential.date("not a date") == nil)
        #expect(RtcCredential.parse(Data("[]".utf8)) == nil)
    }

    @Test func refusalsKeepTheirStatusCodeAndSentence() {
        let refused = URLSessionRtcMinting.outcome(status: 403, data: Data(#"{"error":"Add app:// to Allowed domains.","code":"no_origin"}"#.utf8))
        #expect(refused == .refused(status: 403, code: "no_origin", message: "Add app:// to Allowed domains."))
        let limited = URLSessionRtcMinting.outcome(status: 429, data: Data(#"{"error":"Too many requests.","code":"rate_limited"}"#.utf8))
        #expect(limited == .refused(status: 429, code: "rate_limited", message: "Too many requests."))
        #expect(URLSessionRtcMinting.outcome(status: 502, data: nil) == .refused(status: 502, code: nil, message: nil))
        #expect(URLSessionRtcMinting.outcome(status: 200, data: Data("{}".utf8)) == .refused(status: 200, code: nil, message: nil), "a 200 without a credential is not one")
        #expect(RtcMintOutcome.refused(status: 429, code: "rate_limited", message: nil).detail == "the call session was refused (429 rate_limited)")
    }
}

@Suite struct ControlChannelTests {
    private func channel() -> (RtcControlChannel, ManualRtcClock, MemorySocketFactory, [String]) {
        let clock = ManualRtcClock()
        let sockets = MemorySocketFactory()
        let control = RtcControlChannel(host: "wss://ws.graine.ai/", sessionId: "0123456789abcdef0123456789abcdef", clock: clock, sockets: sockets)
        return (control, clock, sockets, [])
    }

    @Test func theAddressIsTheSessions() {
        let (control, _, sockets, _) = channel()
        control.open()
        #expect(sockets.sockets.first?.url.absoluteString == "wss://ws.graine.ai/control/v1/0123456789abcdef0123456789abcdef")
        #expect(sockets.sockets.first?.protocols == [], "no subprotocol, no ticket")
    }

    @Test func framesWaitForControlReadyThenGoInOrder() {
        let (control, _, sockets, _) = channel()
        var frames: [String] = []
        var joins: [Bool] = []
        control.onFrame = { frames.append($0) }
        control.onJoined = { joins.append($0) }
        control.open()
        control.send(#"{"type":"app_context","seq":1}"#, kind: "app_context")
        control.send(#"{"type":"app_event","n":1}"#)
        control.send(#"{"type":"app_context","seq":2}"#, kind: "app_context")
        let socket = sockets.sockets[0]
        #expect(socket.sent.isEmpty, "nothing before the join")
        socket.deliver(#"{"type":"control_ready","session_id":"x"}"#)
        #expect(socket.sent == [#"{"type":"app_event","n":1}"#, #"{"type":"app_context","seq":2}"#], "the newest screen replaced the older one")
        #expect(joins == [true])
        socket.deliver(#"{"type":"pong"}"#)
        socket.deliver(#"{"type":"text","data":"Welcome"}"#)
        #expect(frames == [#"{"type":"text","data":"Welcome"}"#], "pong is the channel's own; the rest is the call's")
        control.send(#"{"type":"app_event","n":2}"#)
        #expect(socket.sent.last == #"{"type":"app_event","n":2}"#, "joined: sent at once")
    }

    @Test func theQueueKeepsTheNewest32() {
        let (control, _, sockets, _) = channel()
        control.open()
        for n in 1...40 { control.send(#"{"type":"app_event","n":\#(n)}"#) }
        #expect(control.queued.count == 32)
        #expect(control.queued.first == #"{"type":"app_event","n":9}"#)
        sockets.sockets[0].deliver(#"{"type":"control_ready"}"#)
        #expect(sockets.sockets[0].sent.count == 32)
    }

    @Test func aPingEvery25SecondsOnceJoined() {
        let (control, clock, sockets, _) = channel()
        control.open()
        let socket = sockets.sockets[0]
        clock.advance(60)
        #expect(socket.sent.isEmpty, "no ping before the join")
        socket.deliver(#"{"type":"control_ready"}"#)
        clock.advance(24.9)
        #expect(socket.sent.isEmpty)
        clock.advance(0.2)
        #expect(socket.sent == [#"{"type":"ping"}"#])
        clock.advance(25)
        #expect(socket.sent.count == 2)
    }

    @Test func aCloseUnderTheCallReopensAfterTwoSeconds() {
        let (control, clock, sockets, _) = channel()
        var joins: [Bool] = []
        control.onJoined = { joins.append($0) }
        control.open()
        sockets.sockets[0].deliver(#"{"type":"control_ready"}"#)
        sockets.sockets[0].serverClose(4404, "unknown session")
        #expect(joins == [true, false])
        clock.advance(1.9)
        #expect(sockets.sockets.count == 1)
        clock.advance(0.2)
        #expect(sockets.sockets.count == 2, "opened again")
        control.send(#"{"type":"app_event"}"#)
        #expect(sockets.sockets[1].sent.isEmpty, "queued until it joins again")
        clock.advance(60)
        #expect(sockets.sockets[1].sent.isEmpty, "and no ping from the old join")
    }

    @Test func closedByUsItStaysClosed() {
        let (control, clock, sockets, _) = channel()
        control.open()
        control.close()
        #expect(sockets.sockets[0].closedByClient)
        sockets.sockets[0].serverClose(1005, "gone")
        clock.advance(10)
        #expect(sockets.sockets.count == 1)
        control.send(#"{"type":"app_event"}"#)
        #expect(control.queued.isEmpty)
    }
}
