import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * ONE WEBRTC CALL, END TO END, WITH NOTHING REAL: the call session minted by
 * the test, the SBC scripted in memory as production answers (TRACE.md), the
 * peer scripted, the clock moved by hand. Every deadline of the voice bar's,
 * the one redial, each fallback reason, the gate's refusal, the 12 s budget,
 * the media watch and the hang-up's order.
 */

final class EngineRig {
    let clock: ManualRtcClock
    let sockets = MemorySocketFactory()
    let sbc = ScriptedSbc()
    let media = ScriptedMedia()
    let minting = ScriptedMinting()
    let audio = RecordingAudioControl()
    private(set) var events: [GraineRtcEvent] = []
    private(set) var mintSessionIds: [String] = []
    let engine: RtcCallEngine

    /// `direct`: the direct mint the call asks first (DirectRig places such calls); without it, the web route only. `rang`: a call that rang.
    init(
        budget: Double = 12,
        clock: ManualRtcClock = ManualRtcClock(),
        direct: RtcDirectMint? = nil,
        rang: Bool = false,
        body: @escaping (String) -> Data = { id in Data(#"{"publishableKey":"pk_test_rig","session_id":"\#(id)"}"#.utf8) }
    ) {
        self.clock = clock
        let parts = RtcCallEngine.Parts(
            clock: clock,
            sockets: sockets,
            minting: minting,
            random: CountingRandom(),
            makeMedia: { [media] _ in media },
            audio: audio,
            direct: direct
        )
        var ids: [String] = []
        let request = GraineRtcRequest(
            baseUrl: "https://www.graine.ai/",
            controlHost: "wss://ws.graine.ai",
            mintBody: { id in
                ids.append(id)
                return body(id)
            },
            sdkVersion: "0.7.0",
            budgetSeconds: budget,
            debug: true,
            rang: rang
        )
        engine = RtcCallEngine(request: request, parts: parts)
        let sbc = self.sbc
        sockets.onOpen = { socket in if socket.protocols == ["sip"] { sbc.attach(socket) } }
        engine.onEvent = { [weak self] event in self?.events.append(event) }
    }

    /// Open every SIP socket that has not opened yet (the TLS and WebSocket handshakes, instantly).
    func openSip() {
        for socket in sockets.sip where !opened.contains(ObjectIdentifier(socket)) {
            opened.insert(ObjectIdentifier(socket))
            socket.open()
        }
    }
    private var opened = Set<ObjectIdentifier>()

    /// Prepare, register and begin: everything up to the audio.
    func ready() {
        engine.prepare()
        openSip()
        engine.begin()
    }

    /// All the way to a live call.
    func live() {
        ready()
        engine.audioActivated()
        media.ice(.connected)
    }

    /// The SBC says nothing to an INVITE (nor challenges a REGISTER): the test writes each reply to each INVITE, when it says.
    func answerByHand() {
        sbc.challenge = false
        sbc.sendTrying = false
        sbc.inviteFinal = nil
    }

    var invites: [SipMessage] { sbc.received.filter { $0.method == "INVITE" && $0.toTag == nil } }

    var names: [String] {
        events.compactMap { event in
            switch event {
            case .ready: return "ready"
            case .connected: return "connected"
            case .speaking(let on): return "speaking(\(on))"
            case .reconnecting(let on): return "reconnecting(\(on))"
            case .level, .row, .audio: return nil
            case .control: return "control"
            case let .unreachable(reason, _): return "unreachable(\(reason.rawValue))"
            case let .refused(code, _): return "refused(\(code))"
            case .ended(.remote): return "ended(remote)"
            case .ended(.dropped): return "ended(dropped)"
            case .log: return nil
            }
        }
    }

    var lines: [String] {
        events.compactMap { if case .log(let line) = $0 { return line }; return nil }
    }

    var levels: [Double] {
        events.compactMap { if case .level(let value) = $0 { return value }; return nil }
    }

    var reconnecting: [String] { names.filter { $0.hasPrefix("reconnecting") } }

    /// Their BYE for the call's dialog.
    func theirBye() {
        guard let invite = invites.last else { return }
        sockets.sip.last?.deliver([
            "BYE sip:c@h.invalid SIP/2.0", "Via: SIP/2.0/WSS 198.51.100.7;branch=z9hG4bKbye",
            "From: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj", "To: \(invite.header("From")!)",
            "Call-ID: \(invite.callId!)", "CSeq: 1 BYE", "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
    }
}

@Suite struct RtcCallEngineTests {
    @Test func dialsOnlyOnceTheAudioRunsThenConnects() throws {
        let rig = EngineRig()
        rig.engine.prepare()
        #expect(rig.minting.requests.first?.url.absoluteString == "https://www.graine.ai/api/embed/rtc-session")
        #expect(rig.minting.requests.first?.body["session_id"] as? String == rig.engine.sessionId)
        #expect(rig.engine.sessionId.count == 32)
        #expect(rig.media.servers == MintFixture.credential.iceServers, "the mint's ICE servers")
        rig.openSip()
        #expect(rig.names == ["ready"], "minted, registered, offered")
        #expect(rig.sbc.received.filter { $0.method == "REGISTER" }.count == 2, "challenged, then authorised")
        rig.engine.begin()
        #expect(rig.sockets.control.first?.url.absoluteString == "wss://ws.graine.ai/control/v1/\(rig.engine.sessionId)")
        #expect(rig.invites.isEmpty, "no INVITE before CallKit hands the audio over")
        rig.engine.audioActivated()
        try #require(rig.invites.count == 2, "challenged, then authorised")
        let invite = rig.invites[1]
        #expect(invite.requestUri == "sip:app-\(MintFixture.credential.applicationSid)@\(MintFixture.credential.realm)")
        #expect(invite.header("X-Graine-Session-Id") == rig.engine.sessionId)
        #expect(invite.header("X-Application-Sid") == MintFixture.credential.applicationSid)
        #expect(invite.body == SdpCodecs.prefer(TraceSdp.offer) || invite.body == TraceSdp.offer)
        #expect(rig.media.appliedAnswers == [TraceSdp.answer])
        #expect(!rig.names.contains("connected"), "answered is not connected: the media path is")
        rig.media.ice(.checking)
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])
        #expect(rig.audio.steps == ["begins", "activated"])
    }

    /// The header the server signs the leg by: without it the call is anonymous (no identity, no memory).
    @Test func theAgentHeaderIsTheMintsAgent() throws {
        let rig = EngineRig()
        rig.live()
        #expect(rig.invites.allSatisfy { $0.headerValues("X-Graine-Agent-Id") == [MintFixture.credential.agentId] })
        var other = MintFixture.credential
        other.agentId = "agent-from-the-mint-only"
        let second = EngineRig()
        second.minting.outcome = .credential(other)
        second.live()
        #expect(second.invites.last?.header("X-Graine-Agent-Id") == "agent-from-the-mint-only")
    }

    @Test func eventsBeforeAListenerAreKept() {
        let rig = EngineRig()
        rig.engine.onEvent = nil
        rig.engine.prepare()
        rig.openSip()
        #expect(rig.names.isEmpty)
        var late: [String] = []
        rig.engine.onEvent = { if case .ready = $0 { late.append("ready") } }
        #expect(late == ["ready"], "held for whoever listens — the answer to a ring prepared earlier")
    }

    @Test func aRefusedMintFallsBackWithItsReason() {
        for outcome in [
            RtcMintOutcome.refused(status: 429, code: "rate_limited", message: "Too many requests."),
            .refused(status: 403, code: "no_origin", message: "Add app://"),
            .refused(status: 502, code: nil, message: nil),
            .unreachable("offline"),
        ] {
            let rig = EngineRig()
            rig.minting.outcome = outcome
            rig.ready()
            #expect(rig.names == ["unreachable(mint_failed)"], "\(outcome)")
            #expect(rig.sockets.sip.isEmpty, "nothing registered")
            #expect(rig.audio.steps == ["begins", "ends"])
        }
    }

    /// A gate's refusal ends the call in the gate's words: the socket would refuse it the same way.
    @Test func aGateRefusalEndsTheCallWithoutFallingBack() throws {
        for code in ["insufficient_credits", "parent_out_of_credits", "monthly_cap", "agent_off", "agent_deleted"] {
            let rig = EngineRig()
            rig.minting.outcome = .refused(status: code.hasPrefix("agent") ? 409 : 402, code: code, message: "No, because \(code).")
            rig.ready()
            #expect(rig.names == ["refused(\(code))"])
            guard case let .refused(_, message)? = rig.events.first(where: { if case .refused = $0 { return true }; return false }) else {
                Issue.record("no refusal")
                continue
            }
            #expect(message == "No, because \(code).")
        }
    }

    @Test func aRefusedOrSilentRegistrationFallsBack() {
        let refused = EngineRig()
        refused.sbc.registerReply = 403
        refused.ready()
        #expect(refused.names == ["unreachable(register_failed)"])

        let silent = EngineRig()
        silent.sbc.challenge = false
        silent.sbc.registerReply = nil
        silent.ready()
        silent.clock.advance(11.9)
        #expect(silent.names.isEmpty)
        silent.clock.advance(0.2)
        #expect(silent.names == ["unreachable(register_failed)"], "the budget names the stage it stopped at")
    }

    @Test func noReplyGetsOneFreshConnectionThenFallsBack() {
        let rig = EngineRig(budget: 60)
        rig.sbc.sendTrying = false
        rig.sbc.challenge = false
        rig.sbc.inviteFinal = nil
        rig.ready()
        rig.engine.audioActivated()
        #expect(rig.invites.count == 1)
        rig.clock.advance(3.9)
        #expect(rig.sockets.sip.count == 1)
        rig.clock.advance(0.2)
        #expect(rig.sockets.sip.count == 2, "a new socket, registered again on the same credential")
        #expect(rig.minting.requests.count == 1, "the same mint")
        rig.openSip()
        #expect(rig.invites.count == 2, "dialled again")
        rig.clock.advance(4.1)
        #expect(rig.names == ["ready", "unreachable(no_response)"])
    }

    /// 16 Oct: the SBC said "trying" and the call never reached the agent, every other tap.
    @Test func aStuckDialIsCancelledAndDialledAgainInsideTheBudgetAndConnects() {
        let rig = EngineRig()                      // the real 12 s budget
        rig.sbc.challenge = false
        rig.sbc.inviteFinal = nil                  // 100 Trying, then nothing
        rig.ready()
        rig.engine.audioActivated()
        #expect(rig.invites.count == 1)
        rig.clock.advance(0.4)
        #expect(rig.sockets.sip.count == 1, "heard: still waiting for the answer")
        rig.clock.advance(0.2)
        #expect(rig.sbc.received.contains { $0.method == "CANCEL" }, "the stuck INVITE is cancelled, not left on the server")
        #expect(rig.sockets.sip.count == 2, "a fresh connection")
        #expect(rig.minting.requests.count == 1, "on the same credential")
        rig.sbc.inviteFinal = 200                  // this dial gets through
        rig.openSip()
        #expect(rig.invites.count == 2, "dialled again")
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])
    }

    @Test func heardButNeverAnsweredTwiceFallsBackWithNoAnswer() {
        let rig = EngineRig(budget: 60)
        rig.sbc.challenge = false
        rig.sbc.inviteFinal = nil
        rig.ready()
        rig.engine.audioActivated()
        rig.clock.advance(0.6)
        #expect(rig.sockets.sip.count == 2)
        rig.openSip()
        rig.clock.advance(0.4)
        #expect(rig.names == ["ready"], "the second dial gets its own half second")
        rig.clock.advance(0.2)
        #expect(rig.names == ["ready", "unreachable(no_answer)"])
    }

    // MARK: The answer clock runs from the INVITE with credentials' own reply

    /// 20 Oct 2026, production: answered 181 ms after its own reply and dialled again anyway — timed from the first INVITE's reply.
    @Test func aChallengedDialAnsweredInsideHalfASecondOfItsOwnReplyIsNeverDialledAgain() throws {
        let rig = EngineRig()
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        let sip = rig.sockets.sip[0]
        let first = try #require(rig.invites.first)
        sip.deliver(ScriptedSbc.reply(first, 100))           // 100 Trying to the first INVITE: a clock starts for it…
        rig.clock.advance(0.03)
        sip.deliver(ScriptedSbc.challenge(first))            // …and stops at the challenge
        let second = try #require(rig.invites.last)
        #expect(rig.invites.count == 2 && second.header("Authorization") != nil, "sent again with credentials")
        rig.clock.advance(0.47)
        sip.deliver(ScriptedSbc.reply(second, 100))          // the INVITE with credentials' own reply, 500 ms in
        rig.clock.advance(0.425)                             // answered 425 ms after it: 925 ms after the first reply
        sip.deliver(ScriptedSbc.answer(second))
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])
        #expect(rig.sockets.sip.count == 1, "a healthy, challenged call was dialled a second time")
        #expect(!rig.sbc.received.contains { $0.method == "CANCEL" })
        #expect(rig.lines.contains { $0.contains("challenged (401) after 30 ms") })
    }

    /// The 407 itself used to count as the reply the half second ran from.
    @Test func aChallengeIsNotHeardEvenWithNoReplyBeforeIt() throws {
        let rig = EngineRig()
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        let sip = rig.sockets.sip[0]
        rig.clock.advance(0.01)
        sip.deliver(ScriptedSbc.challenge(try #require(rig.invites.first), 407))   // a proxy challenge, no 100 Trying before it
        let second = try #require(rig.invites.last)
        #expect(second.header("Proxy-Authorization") != nil)
        rig.clock.advance(0.6)
        #expect(rig.sockets.sip.count == 1, "the challenge started an answer clock")
        sip.deliver(ScriptedSbc.reply(second, 100))
        rig.clock.advance(0.4)
        sip.deliver(ScriptedSbc.answer(second))
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])
        #expect(rig.sockets.sip.count == 1)
    }

    @Test func anInviteWithCredentialsThatHearsNothingIsNoResponseNotAStuckDial() throws {
        let rig = EngineRig(budget: 60)
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        let sip = rig.sockets.sip[0]
        let first = try #require(rig.invites.first)
        sip.deliver(ScriptedSbc.reply(first, 100))
        sip.deliver(ScriptedSbc.challenge(first))
        rig.clock.advance(3.9)
        #expect(rig.sockets.sip.count == 1, "an answer clock ran for an INVITE that has heard nothing")
        rig.clock.advance(0.2)
        #expect(rig.sockets.sip.count == 2, "silence from the INVITE in flight: one fresh connection")
        #expect(rig.lines.contains { $0.contains("no reply to the INVITE") })
    }

    @Test func anAnswerStillBeingAppliedWhenTheHalfSecondRunsOutIsNotAStuckDial() throws {
        let rig = EngineRig()
        rig.answerByHand()
        rig.media.holdAnswer = true
        rig.ready()
        rig.engine.audioActivated()
        let sip = rig.sockets.sip[0]
        sip.deliver(ScriptedSbc.challenge(try #require(rig.invites.first)))
        let second = try #require(rig.invites.last)
        sip.deliver(ScriptedSbc.reply(second, 100))
        rig.clock.advance(DialRules.answerAfterHeard - 0.001)
        sip.deliver(ScriptedSbc.answer(second))              // the 200 is in; its SDP is still being applied
        rig.clock.advance(1)
        #expect(rig.sockets.sip.count == 1, "an answered dial was dialled again while its answer was applied")
        #expect(!rig.sbc.received.contains { $0.method == "CANCEL" || $0.method == "BYE" })
        rig.media.finishAnswer()
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])
    }

    // MARK: A dial given up on ends on the server, on its own socket

    @Test func aStuckDialIsCancelledOnItsOwnSocketWhichStaysUntilItsInviteHasItsFinalAnswer() throws {
        let rig = EngineRig()
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        let old = rig.sockets.sip[0]
        let first = try #require(rig.invites.first)
        old.deliver(ScriptedSbc.reply(first, 100))
        rig.clock.advance(0.04)
        old.deliver(ScriptedSbc.challenge(first))
        let second = try #require(rig.invites.last)
        rig.clock.advance(0.2)
        old.deliver(ScriptedSbc.reply(second, 100))          // its own reply — and then nothing
        rig.clock.advance(DialRules.answerAfterHeard - 0.01)
        #expect(rig.sockets.sip.count == 1)
        rig.clock.advance(0.02)
        #expect(rig.sockets.sip.count == 2, "dialled again on a fresh connection")
        let cancels = old.sentMessages.filter { $0.method == "CANCEL" }
        #expect(cancels.map(\.topViaBranch) == [second.topViaBranch], "the INVITE with credentials is the one cancelled")
        #expect(old.sentMessages.last { $0.method == "REGISTER" }?.header("Expires") == "0", "its registration went at once")
        rig.clock.advance(2.5)
        #expect(!old.closedByClient, "the socket the CANCEL's ending travels on went first")
        old.deliver(ScriptedSbc.reply(second, 487, toTag: "t487"))
        #expect(old.sentMessages.last?.method == "ACK", "the 487 is ACKed on its own socket")
        rig.clock.advance(0.1)
        #expect(old.closedByClient, "then that socket goes")
        #expect(rig.names == ["ready"], "the old dial told this call nothing")
    }

    @Test func anAnswerThatCrossesAnAbandonedDialsCancelIsAckedAndEndedOnItsOwnSocket() throws {
        let rig = EngineRig()
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        let old = rig.sockets.sip[0]
        old.deliver(ScriptedSbc.challenge(try #require(rig.invites.first)))
        let second = try #require(rig.invites.last)
        old.deliver(ScriptedSbc.reply(second, 100))
        rig.clock.advance(DialRules.answerAfterHeard + 0.01)
        #expect(rig.sockets.sip.count == 2)
        #expect(old.sentMessages.filter { $0.method == "CANCEL" }.count == 1)
        // The server answered as the CANCEL left: that leg exists now, and only an ACK and a BYE end it.
        old.deliver(ScriptedSbc.answer(second))
        #expect(old.sentMessages.suffix(2).map { $0.method ?? "reply" } == ["ACK", "BYE"])
        #expect(old.sentMessages.last?.requestUri == "sip:198.51.100.7:5060;transport=tcp")
        rig.clock.advance(0.1)
        #expect(old.closedByClient, "the BYE answered, that socket goes")
        #expect(rig.media.appliedAnswers.isEmpty, "the abandoned dial's answer was taken for this call's")
        #expect(rig.names == ["ready"])
    }

    @Test func anAbandonedDialWhoseInviteNeverSettlesLetsItsSocketGoAfterTheGrace() throws {
        let rig = EngineRig(budget: 60)
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        let old = rig.sockets.sip[0]
        old.deliver(ScriptedSbc.challenge(try #require(rig.invites.first)))
        old.deliver(ScriptedSbc.reply(try #require(rig.invites.last), 100))
        rig.clock.advance(DialRules.answerAfterHeard)
        #expect(rig.sockets.sip.count == 2)
        rig.clock.advance(DialRules.abandonedDialGrace - 0.1)
        #expect(!old.closedByClient)
        rig.clock.advance(0.2)
        #expect(old.closedByClient, "a dial with no final answer held its socket for ever")
    }

    @Test func aHangUpWhileItRingsCancelsTheDialAndKeepsItsSocketUntilTheDialHasEnded() throws {
        let rig = EngineRig()
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        let sip = rig.sockets.sip[0]
        sip.deliver(ScriptedSbc.challenge(try #require(rig.invites.first)))
        let second = try #require(rig.invites.last)
        sip.deliver(ScriptedSbc.reply(second, 100))
        rig.engine.hangUp()
        #expect(sip.sentMessages.filter { $0.method == "CANCEL" }.map(\.topViaBranch) == [second.topViaBranch])
        rig.clock.advance(1)
        #expect(!sip.closedByClient, "the socket went before the CANCEL could finish")
        sip.deliver(ScriptedSbc.reply(second, 487, toTag: "t487"))
        rig.clock.advance(0.1)
        #expect(sip.closedByClient)
    }

    @Test func aHangUpBeforeTheInviteWithCredentialsWasHeardCancelsItAtItsFirstReply() throws {
        let rig = EngineRig()
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        let sip = rig.sockets.sip[0]
        let first = try #require(rig.invites.first)
        sip.deliver(ScriptedSbc.reply(first, 100))
        sip.deliver(ScriptedSbc.challenge(first))
        let second = try #require(rig.invites.last)
        rig.engine.hangUp()
        #expect(!sip.sentMessages.contains { $0.method == "CANCEL" }, "a CANCEL for an INVITE nothing has replied to")
        rig.clock.advance(2.5)
        sip.deliver(ScriptedSbc.reply(second, 100))
        #expect(sip.sentMessages.filter { $0.method == "CANCEL" }.map(\.topViaBranch) == [second.topViaBranch], "cancelled at its first reply")
        sip.deliver(ScriptedSbc.answer(second))              // and an answer that crossed that CANCEL is ended
        #expect(sip.sentMessages.filter { $0.method == "BYE" }.count == 1)
        rig.clock.advance(0.1)
        #expect(sip.closedByClient)
    }

    @Test func answeredButNoMediaWithin8Seconds() {
        let rig = EngineRig(budget: 60)
        rig.ready()
        rig.engine.audioActivated()
        #expect(rig.media.appliedAnswers.count == 1)
        rig.media.ice(.checking)
        rig.clock.advance(7.9)
        #expect(!rig.names.contains { $0.hasPrefix("unreachable") })
        rig.clock.advance(0.2)
        #expect(rig.names == ["ready", "unreachable(ice_timeout)"])
        #expect(rig.sbc.received.contains { $0.method == "BYE" }, "the answered call is ended on the SBC")
    }

    @Test func aPolicyRefusalFallsBackAtOnceAServerErrorGetsASecondDial() {
        let refused = EngineRig()
        refused.sbc.inviteFinal = 403
        refused.ready()
        refused.engine.audioActivated()
        #expect(refused.names == ["ready", "unreachable(error)"])
        #expect(refused.sockets.sip.count == 1, "no second dial for a refusal")

        let failing = EngineRig()
        failing.sbc.inviteFinal = 503
        failing.ready()
        failing.engine.audioActivated()
        #expect(failing.sockets.sip.count == 2)
        failing.openSip()
        #expect(failing.names == ["ready", "unreachable(error)"])
        #expect(failing.invites.count == 4, "two dials, each challenged")
    }

    /// 0.14.0: the 12 s run from the mint's answer — a slow mint is the web route's wait (its own request gives up at 10 s), not WebRTC's.
    @Test func theWholeAttemptHas12SecondsFromTheMintsAnswer() {
        let rig = EngineRig()
        rig.minting.hold = true
        rig.ready()
        rig.clock.advance(20)
        #expect(rig.names.isEmpty, "the mint still on its way: no budget spent yet")
        rig.minting.release()
        rig.openSip()
        #expect(rig.names == ["ready"])
        rig.clock.advance(11.9)
        #expect(rig.names == ["ready"], "CallKit has not handed the audio over: nothing dialled, the budget still running")
        rig.clock.advance(0.2)
        #expect(rig.names == ["ready", "unreachable(error)"], "12 s after the mint answered, not 12 s after the tap")
    }

    @Test func aCallPreparedBeforeTheTapHasItsBudgetFromTheTap() {
        let rig = EngineRig()
        rig.engine.prepare()
        rig.openSip()
        rig.clock.advance(30)                   // minted and ready long before the tap
        rig.engine.begin()
        rig.clock.advance(11.9)
        #expect(rig.names == ["ready"])
        rig.clock.advance(0.2)
        #expect(rig.names == ["ready", "unreachable(error)"])
    }

    @Test func withoutCallKitTheAudioIsStartedDirectlyThenTheCallDials() {
        let rig = EngineRig()
        rig.ready()
        var started: Bool?
        rig.engine.startAudioDirectly { started = $0 }
        #expect(started == true)
        #expect(rig.audio.steps == ["begins", "direct"])
        #expect(rig.invites.count == 2)
        let failing = EngineRig()
        failing.audio.directStarts = false
        failing.ready()
        failing.engine.startAudioDirectly { started = $0 }
        #expect(started == false)
        #expect(failing.invites.isEmpty)
    }

    @Test func aLostPathIsRestartedOnceThenDropped() throws {
        let rig = EngineRig()
        rig.live()
        rig.media.ice(.disconnected)
        rig.clock.advance(2.9)
        #expect(rig.media.reoffers.isEmpty)
        rig.clock.advance(0.2)
        #expect(rig.media.reoffers == [true], "an ICE restart")
        let reinvite = try #require(rig.sbc.received.last { $0.method == "INVITE" && $0.toTag != nil })
        #expect(reinvite.requestUri == "sip:198.51.100.7:5060;transport=tcp")
        #expect(reinvite.header("Content-Type") == "application/sdp")
        #expect(rig.media.appliedAnswers.count == 2, "its answer applied")
        rig.media.ice(.connected)
        rig.clock.advance(20)
        #expect(!rig.names.contains("ended(dropped)"), "back")
        // Lost again: the restart was spent, so it is dropped when the path does not come back.
        rig.media.ice(.disconnected)
        rig.clock.advance(9.9)
        #expect(!rig.names.contains("ended(dropped)"))
        rig.clock.advance(0.2)
        #expect(rig.names.last == "ended(dropped)")
        #expect(rig.media.reoffers == [true])
        #expect(rig.sbc.received.contains { $0.method == "BYE" })
    }

    @Test func aFailedPathIsRestartedAtOnce() {
        let rig = EngineRig()
        rig.live()
        rig.media.ice(.failed)
        #expect(rig.media.reoffers == [true])
        rig.clock.advance(10.1)
        #expect(rig.names.last == "ended(dropped)", "never back")
    }

    @Test func theirByeEndsTheCall() throws {
        let rig = EngineRig()
        rig.live()
        let invite = try #require(rig.invites.last)
        rig.sockets.sip.last?.deliver([
            "BYE sip:c@h.invalid SIP/2.0", "Via: SIP/2.0/WSS 198.51.100.7;branch=z9hG4bKbye",
            "From: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj", "To: \(invite.header("From")!)",
            "Call-ID: \(invite.callId!)", "CSeq: 1 BYE", "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
        #expect(rig.names.last == "ended(remote)")
        #expect(rig.media.closed)
        #expect(rig.audio.steps.last == "ends")
    }

    @Test func aByeBeforeTheMediaFallsBack() throws {
        let rig = EngineRig()
        rig.ready()
        rig.engine.audioActivated()
        let invite = try #require(rig.invites.last)
        rig.sockets.sip.last?.deliver([
            "BYE sip:c@h.invalid SIP/2.0", "Via: SIP/2.0/WSS 198.51.100.7;branch=z9hG4bKbye",
            "From: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj", "To: \(invite.header("From")!)",
            "Call-ID: \(invite.callId!)", "CSeq: 1 BYE", "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
        #expect(rig.names == ["ready", "unreachable(error)"], "nothing was heard: the socket can still carry it")
    }

    @Test func hangUpIsByeThenUnregisterThenClose() {
        let rig = EngineRig()
        rig.live()
        rig.sockets.control.first?.deliver(#"{"type":"control_ready"}"#)
        let before = rig.events.count
        rig.engine.hangUp()
        let sip = rig.sockets.sip.last!.sentMessages.map { $0.method ?? "reply" }
        let tail = Array(sip.suffix(3))
        #expect(tail == ["BYE", "REGISTER", "REGISTER"], "BYE, then the un-REGISTER (challenged)")
        #expect(rig.sockets.sip.last!.sentMessages.last?.header("Expires") == "0")
        #expect(rig.sockets.control.first?.closedByClient == true)
        #expect(rig.media.closed)
        #expect(rig.audio.steps.last == "ends")
        rig.clock.advance(3)
        #expect(rig.sockets.sip.last?.closedByClient == true, "then the socket")
        #expect(rig.events.count == before, "nothing is reported after a hang-up")
    }

    @Test func hangingUpWhileItDialsCancels() {
        let rig = EngineRig()
        rig.sbc.challenge = false
        rig.sbc.inviteFinal = nil
        rig.ready()
        rig.engine.audioActivated()
        rig.engine.hangUp()
        #expect(rig.sbc.received.contains { $0.method == "CANCEL" })
        #expect(!rig.sbc.received.contains { $0.method == "BYE" })
    }

    @Test func theAgentIsSpeakingWhenItsAudioIsLoud() {
        let rig = EngineRig()
        rig.live()
        rig.media.level.audioLevel = 0.3
        rig.media.level.packetsReceived = 40
        rig.clock.advance(0.2)
        #expect(rig.names.contains("speaking(true)"))
        rig.media.level.audioLevel = 0.015
        rig.clock.advance(1)
        #expect(rig.names.filter { $0.hasPrefix("speaking") } == ["speaking(true)"], "between the two thresholds nothing changes")
        rig.media.level.audioLevel = 0.001
        rig.clock.advance(0.3)
        #expect(!rig.names.contains("speaking(false)"))
        rig.clock.advance(0.5)
        #expect(rig.names.contains("speaking(false)"), "quiet for half a second")
    }

    // MARK: Reconnecting (the call screen's moment) and the agent's level

    @Test func aLostPathIsReconnectingUntilItIsBack() {
        let rig = EngineRig()
        rig.live()
        #expect(rig.reconnecting.isEmpty)
        rig.media.ice(.disconnected)
        #expect(rig.reconnecting == ["reconnecting(true)"], "at once: the screen says so while the path is away")
        rig.clock.advance(3.1)
        #expect(rig.media.reoffers == [true])
        #expect(rig.reconnecting == ["reconnecting(true)"], "the restart is the same moment, said once")
        rig.media.ice(.checking)
        #expect(rig.reconnecting == ["reconnecting(true)"])
        rig.media.ice(.connected)
        #expect(rig.reconnecting == ["reconnecting(true)", "reconnecting(false)"], "back")
        rig.clock.advance(20)
        #expect(!rig.names.contains("ended(dropped)"))
    }

    @Test func aPathBackOnItsOwnEndsTheMomentToo() {
        let rig = EngineRig()
        rig.live()
        rig.media.ice(.disconnected)
        rig.clock.advance(1)
        rig.media.ice(.completed)
        #expect(rig.reconnecting == ["reconnecting(true)", "reconnecting(false)"])
        #expect(rig.media.reoffers.isEmpty, "back before the restart was due")
    }

    @Test func aFailedPathIsReconnectingAsItRestarts() {
        let rig = EngineRig()
        rig.live()
        rig.media.ice(.failed)
        #expect(rig.media.reoffers == [true])
        #expect(rig.reconnecting == ["reconnecting(true)"])
    }

    @Test func neverReconnectingBeforeTheMedia() {
        // Answered, the path lost before it ever connected: a fallback to the socket, never a reconnect.
        let failed = EngineRig()
        failed.ready()
        failed.engine.audioActivated()
        failed.media.ice(.checking)
        failed.media.ice(.failed)
        #expect(failed.names == ["ready", "unreachable(ice_timeout)"])
        #expect(failed.reconnecting.isEmpty)
        let lost = EngineRig()
        lost.ready()
        lost.engine.audioActivated()
        lost.media.ice(.disconnected)
        lost.clock.advance(13)
        #expect(lost.reconnecting.isEmpty)
        #expect(lost.names.last?.hasPrefix("unreachable") == true)
        #expect(lost.levels.isEmpty, "no level before the media")
    }

    @Test func theEndClearsReconnecting() {
        let dropped = EngineRig()
        dropped.live()
        dropped.media.ice(.disconnected)
        dropped.clock.advance(10.1)
        #expect(Array(dropped.names.suffix(2)) == ["reconnecting(false)", "ended(dropped)"], "false before the end")
        let remote = EngineRig()
        remote.live()
        remote.media.ice(.disconnected)
        remote.theirBye()
        #expect(Array(remote.names.suffix(2)) == ["reconnecting(false)", "ended(remote)"])
        // A call that ends while connected says nothing about reconnecting at all.
        let plain = EngineRig()
        plain.live()
        plain.theirBye()
        #expect(plain.reconnecting.isEmpty)
        #expect(plain.names.last == "ended(remote)")
    }

    @Test func theAgentsLevelIsReportedFiveTimesASecondWhileLive() {
        let rig = EngineRig()
        rig.live()
        rig.media.level.audioLevel = 0.3
        rig.media.level.packetsReceived = 40
        rig.clock.advance(1.0)
        #expect(rig.levels == [0.3, 0.3, 0.3, 0.3, 0.3], "what the receiver plays, every 200 ms")
        rig.media.level.audioLevel = 0
        rig.clock.advance(0.2)
        #expect(rig.levels.last == 0, "silence is a level too")
        rig.media.level.audioLevel = 1.7
        rig.clock.advance(0.2)
        #expect(rig.levels.last == 1, "never past full scale")
        rig.media.level.audioLevel = .nan
        rig.clock.advance(0.2)
        #expect(rig.levels.last == 0, "a reading that is not a number is silence")
        let count = rig.levels.count
        rig.theirBye()
        rig.clock.advance(2)
        #expect(rig.levels.count == count, "none after the end")
    }

    @Test func controlFramesQueueThenFlow() {
        let rig = EngineRig()
        rig.engine.prepare()
        rig.engine.sendControl(#"{"type":"app_context","seq":1}"#, kind: "app_context")
        rig.engine.sendControl(#"{"type":"app_context","seq":2}"#, kind: "app_context")
        rig.openSip()
        rig.engine.begin()
        let control = rig.sockets.control.first!
        #expect(control.sent.isEmpty)
        control.deliver(#"{"type":"control_ready"}"#)
        #expect(control.sent == [#"{"type":"app_context","seq":2}"#])
        control.deliver(#"{"type":"text","data":"Welcome"}"#)
        #expect(rig.events.contains { if case .control(let text) = $0 { return text.contains("Welcome") }; return false })
    }

    @Test func aSocketLostBeforeTheDialIsReplacedOnce() {
        let rig = EngineRig()
        rig.ready()
        rig.sockets.sip.last?.serverClose(1006, "gone")
        #expect(rig.sockets.sip.count == 2)
        rig.openSip()
        rig.engine.audioActivated()
        #expect(rig.invites.count == 2, "dialled on the new one")
        rig.sockets.sip.last?.serverClose(1006, "gone")
        #expect(rig.names.last != "ended(dropped)")
    }

    @Test func mutingReachesTheTrack() {
        let rig = EngineRig()
        rig.engine.setMuted(true)
        rig.engine.prepare()
        #expect(rig.media.muted.first == true, "a mute from before the peer existed")
        rig.engine.setMuted(false)
        #expect(rig.media.muted.last == false)
    }
}
