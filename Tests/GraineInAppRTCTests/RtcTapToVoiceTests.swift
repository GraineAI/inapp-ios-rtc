import Foundation
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC
import Testing

/**
 * FROM THE TAP TO THE AGENT'S VOICE, NOTHING WAITS FOR WHAT IT DOES NOT NEED.
 * The dial needs the offer and an open socket: not the registration (the SBC
 * challenges the INVITE itself), not the audio (the greeting waits for the
 * phone's word that it plays). That word needs the audio running steadily for a
 * moment, seen by readings quick enough not to add to the first silence.
 */
@Suite struct RtcTapToVoiceTests {
    private func join(_ rig: EngineRig) {
        rig.sockets.control.last?.deliver(#"{"type":"control_ready"}"#)
    }

    private func readySent(_ rig: EngineRig) -> Int {
        rig.sockets.control.flatMap(\.sent).filter { $0 == GraineRtcSignal.audioReady }.count
    }

    /// Readings at the call's start: each one a little more played and arrived.
    private func playing(_ rig: EngineRig, for seconds: Double, samples: Int = 480, packets: Int = 3) {
        let step = RtcCallEngine.startLevelSeconds
        for _ in 0..<Int((seconds / step).rounded()) {
            rig.media.level.samplesReceived = (rig.media.level.samplesReceived ?? 0) + samples
            rig.media.level.packetsReceived += packets
            rig.clock.advance(step)
        }
    }

    private func answerRegister(_ rig: EngineRig) throws {
        let register = try #require(rig.sbc.received.last { $0.method == "REGISTER" })
        rig.sockets.sip.last?.deliver(ScriptedSbc.reply(register, 200, toTag: "reg1", extra: ["Expires: 300"]))
    }

    // MARK: - the dial

    @Test func theDialGoesWithTheOfferAndTheOpenSocketNotTheRegistration() throws {
        let rig = EngineRig()
        rig.sbc.challenge = false
        rig.sbc.registerReply = nil
        rig.engine.prepare()
        rig.engine.begin()
        #expect(rig.invites.isEmpty, "no socket yet")
        rig.openSip()
        #expect(rig.invites.count == 1, "the socket open, the offer made")
        #expect(rig.sbc.received.contains { $0.method == "REGISTER" }, "the registration goes beside it")
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])

        try answerRegister(rig)
        rig.clock.advance(1)
        #expect(rig.invites.count == 1, "its answer dials nothing")
        #expect(rig.names == ["ready", "connected"], "and moves the live call nowhere")
    }

    @Test func theDialWaitsForTheOfferWhenTheSocketComesFirst() {
        let rig = EngineRig()
        rig.media.offerResult = nil
        rig.engine.prepare()
        rig.engine.begin()
        rig.openSip()
        #expect(rig.invites.isEmpty, "nothing to offer yet")
        rig.media.finishOffer()
        #expect(!rig.invites.isEmpty)
    }

    @Test func aCallPreparedButNotBegunDoesNotDial() {
        let rig = EngineRig()
        rig.sbc.challenge = false
        rig.sbc.registerReply = nil
        rig.engine.prepare()
        rig.openSip()
        #expect(rig.invites.isEmpty, "nothing is dialled before the tap")
        #expect(rig.names.isEmpty, "and it is not ready until it is registered")
    }

    @Test func aRefusedRegistrationLeavesTheDialAlreadyOutToDecide() {
        let rig = EngineRig()
        rig.sbc.challenge = false
        rig.sbc.registerReply = 403
        rig.sbc.holdFinal = true
        rig.engine.prepare()
        rig.engine.begin()
        rig.openSip()
        #expect(rig.invites.count == 1)
        #expect(rig.names == ["ready"], "no fallback: the dial decides")
        rig.sbc.releaseFinal()
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])
    }

    @Test func aDialRefusedAheadOfItsRegistrationIsMadeOnceMoreRegisteredFirstAndTheAppRemembers() {
        let rig = EngineRig()
        rig.sbc.challenge = false
        rig.sbc.registerReply = nil
        rig.sbc.inviteFinal = 403
        rig.engine.prepare()
        rig.engine.begin()
        rig.openSip()
        #expect(rig.invites.count == 1)
        #expect(rig.dialMemory.registrationFirst, "the SBC itself said no: this app registers first from now on")
        #expect(rig.sockets.sip.count == 2, "a fresh connection")
        #expect(!rig.names.contains { $0.hasPrefix("unreachable") }, "no fallback for it")

        rig.sbc.inviteFinal = 200
        rig.sbc.holdFinal = false
        rig.openSip()                              // this socket's REGISTER is not answered: nothing goes
        #expect(rig.invites.count == 1, "registered first")
        rig.sbc.registerReply = 200
        rig.sockets.sip.last?.serverClose(1006, "gone")
        rig.openSip()
        #expect(rig.invites.count == 2, "registered, then dialled")
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])
    }

    @Test func anAppThatRegistersFirstHoldsTheDialForTheRegistration() throws {
        let rig = EngineRig()
        rig.dialMemory.registrationFirst = true
        rig.sbc.challenge = false
        rig.sbc.registerReply = nil
        rig.engine.prepare()
        rig.engine.begin()
        rig.openSip()
        #expect(rig.invites.isEmpty)
        try answerRegister(rig)
        #expect(rig.invites.count == 1)
    }

    @Test func aDialLostAheadOfItsRegistrationIsNotHeldAgainstTheApp() {
        let rig = EngineRig()
        rig.answerByHand()
        rig.engine.prepare()
        rig.engine.begin()
        rig.openSip()
        #expect(rig.invites.count == 1)
        rig.clock.advance(DialRules.heardDeadline(registerSeconds: nil) + 0.1)
        #expect(rig.sockets.sip.count == 2, "silence: a fresh connection")
        #expect(!rig.dialMemory.registrationFirst, "the network's silence says nothing about the SBC")
    }

    // MARK: - the audio around the dial

    @Test func mediaUpBeforeTheAudioComesOnIsNotJudgedAndTheWordWaitsForTheAudio() {
        let rig = EngineRig(startReadings: true)
        rig.ready()
        rig.media.ice(.connected)
        join(rig)
        #expect(rig.names == ["ready", "connected"])
        rig.media.level.samplesReceived = 0
        rig.media.level.playoutSamples = 0
        // CallKit takes its time; packets arrive; nothing plays, as nothing may yet.
        for _ in 0..<50 {
            rig.media.level.packetsReceived += 3
            rig.clock.advance(RtcCallEngine.startLevelSeconds)
        }
        #expect(rig.audio.steps == ["begins"], "no restart, no direct start: CallAudioWatch has that")
        #expect(!rig.names.contains("playoutFailed"))
        #expect(readySent(rig) == 0, "no word while nothing plays")

        rig.engine.audioActivated()
        playing(rig, for: 0.2)
        #expect(readySent(rig) == 1, "said within a fifth of a second of it playing")
    }

    @Test func playoutCountsMovingBeforeTheAudioIsOnAreNotReady() {
        let rig = EngineRig(startReadings: true)
        rig.ready()
        rig.media.ice(.connected)
        join(rig)
        playing(rig, for: 1)
        #expect(readySent(rig) == 0, "the word needs the call's audio on")
        rig.engine.audioActivated()
        playing(rig, for: 0.06)
        #expect(readySent(rig) == 0, "counted from the audio coming on, never from before it")
        playing(rig, for: 0.12)
        #expect(readySent(rig) == 1)
    }

    @Test func aDeactivationBeforeThisCallsAudioIsTheCallBeforesAndNobodysHere() {
        let rig = EngineRig()
        rig.ready()
        rig.engine.audioDeactivated()
        #expect(!rig.sockets.control.flatMap(\.sent).contains { $0.contains("deactivated_live") })
        rig.media.ice(.connected)
        join(rig)
        #expect(!rig.sockets.control.flatMap(\.sent).contains { $0.contains("deactivated_live") })
    }

    @Test func justAfterACallTheAudioIsWatchedALittleLonger() {
        let rig = EngineRig(startReadings: true)
        rig.audio.endedMomentsAgo = true
        rig.live()
        join(rig)
        playing(rig, for: 0.24)
        #expect(readySent(rig) == 0, "the call before's deactivation may still land: the same stretch a booked call has")
        playing(rig, for: 0.18)
        #expect(readySent(rig) == 1)
    }

    @Test func aReadingBetweenTwoReportsDoesNotStartTheSteadyStretchOver() {
        let rig = EngineRig(startReadings: true)
        rig.live()
        join(rig)
        let step = RtcCallEngine.startLevelSeconds
        rig.media.level.samplesReceived = 0
        rig.clock.advance(step)
        rig.media.level.samplesReceived = 480
        rig.clock.advance(step)
        rig.clock.advance(step)                    // the same report again: libwebrtc keeps one for 50 ms
        rig.media.level.samplesReceived = 960
        rig.clock.advance(step)
        #expect(readySent(rig) == 1)
    }

    /// An interruption heard before the audio, with no end ever following: the audio coming on is its end.
    @Test func anInterruptionBeforeTheAudioIsOverOnceTheAudioComesOn() {
        let rig = EngineRig(startReadings: true)
        rig.ready()
        rig.media.ice(.connected)
        join(rig)
        rig.audio.route(.interrupted)
        rig.engine.audioActivated()
        rig.media.level.samplesReceived = 0
        rig.media.level.playoutSamples = 0
        rig.audio.cause = "unit_failed"
        for _ in 0..<5 { rig.clock.advance(RtcCallEngine.startLevelSeconds) }
        #expect(rig.audio.steps.contains("retry unit"), "the playout watch is back: the audio unit is asked for again")
    }

    /// A booked call keeps what it always did here: an interruption stays until it ends.
    @Test func aBookedCallsInterruptionIsLeftAsItWas() {
        let rig = EngineRig(answering: true)
        rig.live()
        join(rig)
        rig.audio.route(.interrupted)
        rig.engine.audioDeactivated()
        rig.engine.audioActivated()
        rig.media.level.samplesReceived = 0
        rig.media.level.playoutSamples = 0
        rig.audio.cause = "unit_failed"
        for _ in 0..<5 { rig.clock.advance(RtcCallEngine.levelSeconds) }
        #expect(!rig.audio.steps.contains("retry unit"))
    }

    @Test func afterACallOnAnyTransportTheAudioIsWatchedALittleLonger() {
        let rig = EngineRig(startReadings: true)
        rig.engine.afterACall = true               // the call before ran on the WebSocket: the audio gate never saw it
        rig.live()
        join(rig)
        playing(rig, for: 0.24)
        #expect(readySent(rig) == 0, "the call before's deactivation may still land")
        playing(rig, for: 0.18)
        #expect(readySent(rig) == 1)
    }

    // MARK: - a dial ahead of its registration, on a slow link

    private func heardAndHeld() -> EngineRig {
        let rig = EngineRig()
        rig.sbc.challenge = false
        rig.sbc.registerReply = nil
        rig.sbc.holdFinal = true
        rig.engine.prepare()
        rig.engine.begin()
        return rig
    }

    @Test func aDialAheadOnASlowSocketIsNotTimedAsAGoodLink() {
        let rig = heardAndHeld()
        rig.clock.advance(2.5)                     // the socket took 2.5 s: the slowest pace
        rig.openSip()
        #expect(rig.invites.count == 1)
        rig.clock.advance(1.0)
        #expect(rig.sockets.sip.count == 1, "one delayed packet does not redial a healthy call")
        rig.clock.advance(0.3)
        #expect(rig.sockets.sip.count == 2, "1.25 s on the slowest link, as a measured one")
    }

    @Test func aDialAheadOnAQuickSocketKeepsHalfASecond() {
        let rig = heardAndHeld()
        rig.clock.advance(0.2)
        rig.openSip()
        rig.clock.advance(0.45)
        #expect(rig.sockets.sip.count == 1)
        rig.clock.advance(0.1)
        #expect(rig.sockets.sip.count == 2)
    }

    // MARK: - the readings

    @Test func theReadingsAreQuickUntilTheFirstWordsAndThenFiveASecond() {
        let rig = EngineRig(startReadings: true)
        rig.live()
        join(rig)
        rig.media.level.audioLevel = 0.3
        playing(rig, for: 0.3)
        #expect(readySent(rig) == 1)
        let before = rig.levels.count
        rig.clock.advance(1.01)
        #expect(rig.levels.count - before == 5, "ready said and the agent heard: five a second")
    }

    @Test func aQuietAgentGetsQuickReadingsForFiveSecondsOnly() {
        let rig = EngineRig(startReadings: true)
        rig.live()
        join(rig)
        rig.media.level.audioLevel = 0
        rig.clock.advance(RtcCallEngine.startLevelFor + 0.1)
        let before = rig.levels.count
        rig.clock.advance(1.01)
        #expect(rig.levels.count - before == 5)
    }

    // MARK: - a booked call: nothing before the person picks up, and its order kept (Sandeep's report, 4 Nov 2026)

    /// However long it rings: prepared, nothing dialled, no channel, no agent. Then the pick-up; then the audio; then the INVITE.
    @Test func aBookedCallDialsOnlyOnceThePersonPickedUpAndItsAudioRuns() throws {
        for ringing in [0.5, 7.0, 31.0, 44.0] {
            let rig = EngineRig(answering: true)
            rig.engine.prepare()
            rig.openSip()
            rig.clock.advance(ringing)
            #expect(rig.invites.isEmpty, "\(ringing) s of ringing: nothing dialled")
            #expect(rig.sockets.control.isEmpty, "and no conversation opened")
            #expect(rig.audio.steps == ["begins"], "and nothing plays or records")
            rig.engine.begin()                     // the person picks up
            rig.clock.advance(0.4)
            #expect(rig.invites.isEmpty, "picked up, its audio not yet running: not yet")
            rig.engine.audioActivated()
            #expect(!rig.invites.isEmpty, "the audio runs: the INVITE")
            rig.media.ice(.connected)
            #expect(rig.names == ["ready", "connected"])
        }
    }

    @Test func aBookedCallPickedUpBeforeItsRegistrationWaitsForIt() throws {
        let rig = EngineRig(answering: true)
        rig.sbc.challenge = false
        rig.sbc.registerReply = nil
        rig.engine.prepare()
        rig.openSip()
        rig.engine.begin()
        rig.engine.audioActivated()
        #expect(rig.invites.isEmpty, "a booked call registers first")
        try answerRegister(rig)
        #expect(rig.invites.count == 1)
    }

    @Test func aBookedCallsAudioIsWatchedTheFullSteadyStretchAtFiveReadingsASecond() {
        let rig = EngineRig(answering: true, startReadings: true)
        rig.live()
        join(rig)
        rig.media.level.samplesReceived = 0
        rig.clock.advance(RtcCallEngine.levelSeconds)           // the baseline
        rig.media.level.samplesReceived = 1_600
        rig.clock.advance(RtcCallEngine.levelSeconds)
        #expect(readySent(rig) == 0, "0.2 s is not yet steady for a booked call")
        rig.media.level.samplesReceived = 3_200
        rig.clock.advance(RtcCallEngine.levelSeconds)
        #expect(readySent(rig) == 1)
        #expect(rig.levels.count == 3, "five readings a second from the start: its timing is untouched")
    }

    @Test func aBookedCallHeardOnlyAfterItsAudioRunsAndTheGreetingWaitsForTheWord() {
        let rig = EngineRig(answering: true)
        rig.engine.prepare()
        rig.openSip()
        rig.clock.advance(30)
        rig.engine.begin()
        rig.clock.advance(3)
        #expect(readySent(rig) == 0, "picked up, nothing playing: the greeting is held")
        var started: Bool?
        rig.engine.startAudioDirectly { started = $0 }          // CallKit never activated it: the watch's rescue
        #expect(started == true)
        #expect(!rig.invites.isEmpty, "then the INVITE")
    }

    // MARK: - counted from the tap

    @Test func theCallsRowsCountFromTheTapNotFromWhenTheCallWasHandedOver() throws {
        let rig = EngineRig(startReadings: true)
        rig.engine.tapAgoSeconds = 0.25
        rig.live()
        join(rig)
        rig.media.level.audioLevel = 0.3
        playing(rig, for: 0.12)
        let voice = try #require(rig.sockets.control.flatMap(\.sent).first { $0.contains(#""name":"voice""#) })
        #expect(voice.contains(#""tap_to_voice_ms":310"#), "\(voice)")
    }
}
