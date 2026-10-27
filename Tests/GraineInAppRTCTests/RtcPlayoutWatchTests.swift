import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * 0.14.4, THE SPEAKER WATCHED: a live call whose playout runs tells its
 * control channel the audio is ready (once — the agent's greeting waits for
 * it); audio arriving with nothing played is started again, once, and a call
 * still unheard after that is said unheard, for the core to end; the system
 * taking the audio back mid-call, and the direct start that rescues it, are
 * said in `audio` rows. Never judged on the agent's level, nor while nothing
 * arrives. Every mint and grant body for the call carries the phone's promise.
 */

/// The `audio` rows a call's control channel sent: their data.
private func audioRows(_ rig: EngineRig) -> [[String: Any]] {
    rig.sockets.control.flatMap(\.sent).compactMap { text in
        guard let object = JSON.object(from: text), let event = object["event"] as? [String: Any],
              JSON.string(event["name"]) == "audio" else { return nil }
        return event["data"] as? [String: Any]
    }
}

private func events(_ rig: EngineRig) -> [String] { audioRows(rig).map { JSON.string($0["event"]) } }

private func join(_ rig: EngineRig) {
    rig.sockets.control.last?.deliver(#"{"type":"control_ready"}"#)
}

/// Readings every 0.2 s for `seconds`: each one `samples` more played and `packets` more arrived.
private func readings(_ rig: EngineRig, for seconds: Double, samples: Int?, packets: Int, playout: Int? = nil) {
    for _ in 0..<Int((seconds / RtcCallEngine.levelSeconds).rounded()) {
        if let samples = samples { rig.media.level.samplesReceived = (rig.media.level.samplesReceived ?? 0) + samples }
        if let playout = playout { rig.media.level.playoutSamples = (rig.media.level.playoutSamples ?? 0) + playout }
        rig.media.level.packetsReceived += packets
        rig.clock.advance(RtcCallEngine.levelSeconds)
    }
}

private func unheard(_ rig: EngineRig) -> [String] {
    rig.events.compactMap { if case .playoutFailed(let why) = $0 { return why }; return nil }
}

@Suite struct RtcPlayoutWatchTests {
    @Test func aCallWhosePlayoutRunsSaysItsAudioIsReadyOnce() throws {
        let rig = EngineRig()
        rig.live()
        rig.media.level.samplesReceived = 0
        readings(rig, for: 1, samples: 1_600, packets: 0)
        let control = try #require(rig.sockets.control.first)
        #expect(control.sent.isEmpty, "kept until the channel joins")
        join(rig)
        #expect(control.sent.filter { $0 == GraineRtcSignal.audioReady }.count == 1)
        #expect(events(rig) == ["ready"], "and its row, once")
        #expect(JSON.string(audioRows(rig).first?["via"]) == "callkit")
        readings(rig, for: 2, samples: 1_600, packets: 10)
        #expect(control.sent.filter { $0 == GraineRtcSignal.audioReady }.count == 1, "once per call")
        #expect(!rig.audio.steps.contains("restart") && unheard(rig).isEmpty)
    }

    @Test func libwebrtcsOwnPlayoutCountSaysReadyBeforeAnyPacket() throws {
        let rig = EngineRig()
        rig.live()
        rig.media.level = RtcInboundAudio(audioLevel: 0, totalAudioEnergy: 0, bytesReceived: 0, packetsReceived: 0, packetsLost: 0, jitter: 0, codec: nil)
        rig.media.level.inbound = false
        rig.media.level.playoutSamples = 0
        readings(rig, for: 0.6, samples: nil, packets: 0, playout: 9_600)
        join(rig)
        #expect(rig.sockets.control.first?.sent.contains(GraineRtcSignal.audioReady) == true, "the greeting is held: no packet comes before it")
        #expect(rig.levels.isEmpty, "nothing received: no level")
    }

    @Test func audioThatArrivesUnplayedIsStartedAgainOnce() {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.audio.cause = "interrupted"
        rig.media.level.samplesReceived = 0
        readings(rig, for: 1.8, samples: 0, packets: 10)
        #expect(!rig.audio.steps.contains("restart"), "not before 2 s of it")
        readings(rig, for: 0.4, samples: 0, packets: 10)
        #expect(rig.audio.steps.filter { $0 == "restart" }.count == 1)
        #expect(events(rig) == ["playout_restarted"])
        #expect(JSON.string(audioRows(rig).first?["reason"]) == "interrupted", "what the session said")
        readings(rig, for: 1, samples: 1_600, packets: 10)
        #expect(events(rig) == ["playout_restarted", "ready"], "playing after it: ready, and nothing ends the call")
        readings(rig, for: 5, samples: 1_600, packets: 10)
        #expect(unheard(rig).isEmpty)
    }

    @Test func aCallStillUnheardAfterTheRestartIsSaidUnheardOnce() {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.level.samplesReceived = 0
        readings(rig, for: 2.2, samples: 0, packets: 10)
        #expect(rig.audio.steps.contains("restart"))
        readings(rig, for: 2.8, samples: 0, packets: 10)
        #expect(unheard(rig).isEmpty, "3 s for the restart to take")
        readings(rig, for: 0.4, samples: 0, packets: 10)
        #expect(unheard(rig).count == 1)
        #expect(events(rig) == ["playout_restarted", "failed"])
        #expect(JSON.string(audioRows(rig).last?["reason"]) == "no_playout")
        readings(rig, for: 5, samples: 0, packets: 10)
        #expect(unheard(rig).count == 1 && rig.audio.steps.filter { $0 == "restart" }.count == 1, "said once")
        #expect(!rig.sockets.control.flatMap(\.sent).contains(GraineRtcSignal.audioReady), "never ready")
    }

    @Test func aSpeakerThatTakesNothingIsStartedAgainBeforeAnyPacketButNeverEndsTheCallAlone() {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.level = RtcInboundAudio(audioLevel: 0, totalAudioEnergy: 0, bytesReceived: 0, packetsReceived: 0, packetsLost: 0, jitter: 0, codec: nil)
        rig.media.level.inbound = false
        rig.media.level.playoutSamples = 4_800
        readings(rig, for: 2.2, samples: nil, packets: 0, playout: 0)
        #expect(rig.audio.steps.filter { $0 == "restart" }.count == 1, "the greeting is held for the ready signal: no packet comes to judge by")
        readings(rig, for: 10, samples: nil, packets: 0, playout: 0)
        #expect(unheard(rig).isEmpty && rig.audio.steps.filter { $0 == "restart" }.count == 1, "a count standing still never ends a call alone")
        // The greeting comes once the server stops waiting, and nothing plays it: that ends the call.
        rig.media.level.inbound = true
        rig.media.level.samplesReceived = 0
        readings(rig, for: 2.4, samples: 0, packets: 10, playout: 0)
        #expect(unheard(rig).count == 1)
        #expect(events(rig) == ["playout_restarted", "failed"])
    }

    @Test func aRestartThatWouldNotStartIsUnheardAtOnce() {
        let rig = EngineRig()
        rig.live()
        rig.audio.restarts = false
        rig.media.level.samplesReceived = 0
        readings(rig, for: 2.2, samples: 0, packets: 10)
        #expect(unheard(rig).count == 1)
        join(rig)
        #expect(events(rig) == ["playout_restarted", "failed"])
    }

    @Test func nothingIsJudgedWhileNothingArrivesOrNothingIsCounted() {
        let quiet = EngineRig()
        quiet.live()
        quiet.media.level.samplesReceived = 0
        quiet.media.level.packetsReceived = 40
        readings(quiet, for: 10, samples: 0, packets: 0)
        #expect(!quiet.audio.steps.contains("restart"), "an agent holding its greeting sends nothing: nothing to judge")

        let uncounted = EngineRig()
        uncounted.live()
        readings(uncounted, for: 10, samples: nil, packets: 10)
        #expect(!uncounted.audio.steps.contains("restart") && unheard(uncounted).isEmpty, "a library that counts no samples: never judged")
        join(uncounted)
        #expect(!uncounted.sockets.control.flatMap(\.sent).contains(GraineRtcSignal.audioReady), "nor said ready on a guess")
    }

    @Test func theAudioTakenBackMidCallAndItsRescueAreSaid() {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.engine.audioDeactivated()
        rig.media.level.samplesReceived = 0
        readings(rig, for: 0.6, samples: 1_600, packets: 10)
        #expect(!rig.sockets.control.flatMap(\.sent).contains(GraineRtcSignal.audioReady), "playing without its audio on is not ready")
        var started: Bool?
        rig.engine.startAudioDirectly { started = $0 }
        #expect(started == true && rig.audio.steps.suffix(2) == ["deactivated", "direct"])
        readings(rig, for: 0.4, samples: 1_600, packets: 10)
        #expect(events(rig) == ["deactivated_live", "rescued", "ready"])
        #expect(JSON.string(audioRows(rig)[1]["reason"]) == "deactivated")
        #expect(JSON.string(audioRows(rig)[2]["via"]) == "direct")

        let early = EngineRig()
        early.ready()
        early.engine.audioDeactivated()
        early.engine.startAudioDirectly { _ in }
        early.media.ice(.connected)
        join(early)
        #expect(events(early) == ["rescued"], "before the dial a deactivation is nobody's call; the rescue is said")
        #expect(JSON.string(audioRows(early).first?["reason"]) == "no_activation")
    }

    // MARK: - the route moves (0.14.4: Bluetooth headsets, car kits, the speaker)

    /// Playing for 0.6 s, so the call's audio has been heard.
    private func heard() -> EngineRig {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.level.samplesReceived = 0
        readings(rig, for: 0.6, samples: 1_600, packets: 10)
        return rig
    }

    @Test func aRouteThatMovesDuringAStallIsGivenTimeToSettle() throws {
        let rig = heard()
        readings(rig, for: 1.6, samples: 0, packets: 10)        // a stall begins…
        rig.audio.route(.changed("bluetooth"))                   // …as AirPods connect
        readings(rig, for: 3.8, samples: 0, packets: 10)
        #expect(!rig.audio.steps.contains("restart"), "settling: nothing judged for 4 s")
        readings(rig, for: 2.4, samples: 0, packets: 10)
        #expect(rig.audio.steps.filter { $0 == "restart" }.count == 1, "still nothing 2 s after it settled: started again")
        let route = try #require(audioRows(rig).first { JSON.string($0["event"]) == "route_changed" })
        #expect(JSON.string(route["route"]) == "bluetooth", "the output's kind, never a device's name")
    }

    @Test func aFiveSecondBluetoothHandoverKeepsTheCall() {
        let rig = heard()
        rig.audio.route(.changed("bluetooth"))
        readings(rig, for: 5, samples: 0, packets: 10)          // the hands-free link comes up slowly
        readings(rig, for: 6, samples: 1_600, packets: 10)      // and plays
        #expect(!rig.audio.steps.contains("restart") && unheard(rig).isEmpty, "a healthy call is never restarted, nor ended")
        #expect(events(rig) == ["ready", "route_changed"])
    }

    @Test func silenceAfterTheRouteSettledIsStillRestartedThenEnded() {
        let rig = heard()
        rig.audio.route(.changed("car"))
        readings(rig, for: 5.8, samples: 0, packets: 10)
        #expect(rig.audio.steps.filter { $0 == "restart" }.count == 1, "4 s to settle, then 2 s of silence: started again")
        readings(rig, for: 2.8, samples: 0, packets: 10)
        #expect(unheard(rig).isEmpty, "3 s for the restart to take")
        readings(rig, for: 0.4, samples: 0, packets: 10)
        #expect(unheard(rig).count == 1, "then, as before, the call cannot be heard")
        #expect(events(rig) == ["ready", "route_changed", "playout_restarted", "failed"])
    }

    @Test func aSpeakerToggleMidCallRestartsNothing() {
        let rig = heard()
        rig.audio.route(.changed("speaker"))
        readings(rig, for: 1.2, samples: 0, packets: 10)        // the unit remade for the loudspeaker
        readings(rig, for: 3, samples: 1_600, packets: 10)
        rig.audio.route(.changed("receiver"))
        readings(rig, for: 3, samples: 0, packets: 10)
        readings(rig, for: 2, samples: 1_600, packets: 10)
        #expect(!rig.audio.steps.contains("restart") && unheard(rig).isEmpty)
        #expect(audioRows(rig).compactMap { JSON.string($0["route"]).isEmpty ? nil : JSON.string($0["route"]) } == ["speaker", "receiver"])
    }

    @Test func aRestartAlreadyMadeIsJudgedFromTheEndOfTheSettling() {
        let rig = heard()
        readings(rig, for: 2.2, samples: 0, packets: 10)
        #expect(rig.audio.steps.contains("restart"))
        readings(rig, for: 1, samples: 0, packets: 10)
        rig.audio.route(.changed("bluetooth"))
        readings(rig, for: 5.8, samples: 0, packets: 10)
        #expect(unheard(rig).isEmpty, "it would have ended 3 s after the restart; the move began the clock again")
        readings(rig, for: 1.4, samples: 0, packets: 10)
        #expect(unheard(rig).count == 1, "3 s after the settling, still nothing: unheard")
    }

    @Test func anInterruptionPausesTheWatchUntilItEndsThenSettles() {
        let rig = heard()
        rig.audio.route(.interrupted)
        readings(rig, for: 10, samples: 0, packets: 10)
        #expect(!rig.audio.steps.contains("restart"), "a restart while the system holds the audio could only fail")
        rig.audio.route(.resumed("receiver"))
        readings(rig, for: 3.8, samples: 0, packets: 10)
        #expect(!rig.audio.steps.contains("restart"))
        readings(rig, for: 2.4, samples: 0, packets: 10)
        #expect(rig.audio.steps.contains("restart"), "silence after it settled is judged as before")
    }

    @Test func aMoveBeforeTheAudioWasEverHeardDoesNotDelayTheRescue() {
        let rig = EngineRig()
        rig.live()
        rig.media.level.samplesReceived = 0
        readings(rig, for: 0.4, samples: 0, packets: 10)
        rig.audio.route(.changed("speaker"))                     // the call's own speaker routing, as it opens
        readings(rig, for: 2.2, samples: 0, packets: 10)
        #expect(rig.audio.steps.contains("restart"), "nothing healthy to protect: a call that never played is rescued at once")
    }

    @Test func routeRowsSayEachNewKindOnceAndNoMoreThanEight() {
        let rig = heard()
        for kind in ["bluetooth", "bluetooth", "speaker", "receiver", "speaker", "wired", "airplay", "car", "receiver", "speaker", "bluetooth"] {
            rig.audio.route(.changed(kind))
        }
        let routes = audioRows(rig).filter { JSON.string($0["event"]) == "route_changed" }.map { JSON.string($0["route"]) }
        #expect(routes == ["bluetooth", "speaker", "receiver", "speaker", "wired", "airplay", "car", "receiver"])
        #expect(RtcAudioRoute.kind("BluetoothHFP") == "bluetooth" && RtcAudioRoute.kind("CarAudio") == "car" && RtcAudioRoute.kind("Headphones") == "wired")
        #expect(RtcAudioRoute.kind("Speaker") == "speaker" && RtcAudioRoute.kind("Receiver") == "receiver" && RtcAudioRoute.kind("AirPlay") == "airplay")
        #expect(RtcAudioRoute.kind("Jo's AirPods") == nil, "a kind, never a name")
    }

    // MARK: - ready only once the audio plays steadily, and again once it comes back (fast redials)

    private func readySent(_ rig: EngineRig) -> Int {
        rig.sockets.control.flatMap(\.sent).filter { $0 == GraineRtcSignal.audioReady }.count
    }

    @Test func theAudioIsSaidReadyOnlyOnceItHasPlayedSteadily() {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.level.samplesReceived = 0
        readings(rig, for: 0.2, samples: 0, packets: 10)       // the first reading: the baseline
        readings(rig, for: 0.2, samples: 1_600, packets: 10)   // playing for one reading…
        #expect(readySent(rig) == 0, "one reading of playout is not yet steady: the greeting would go into audio that may be cut")
        readings(rig, for: 0.2, samples: 1_600, packets: 10)   // …and still playing, \(RtcCallEngine.readyStableSeconds) s on
        #expect(readySent(rig) == 1)
        #expect(events(rig) == ["ready"] && audioRows(rig).first?["reason"] == nil, "a first ready gives no reason")
    }

    @Test func aStaleDeactivationInsideTheSteadyStretchHoldsReadyUntilTheRescuePlays() {
        // A redial within a second of the last call: CallKit's late deactivation of the call before lands on this one
        // just after its audio started. The greeting must not start into audio about to be cut.
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.level.samplesReceived = 0
        readings(rig, for: 0.2, samples: 0, packets: 10)
        readings(rig, for: 0.2, samples: 1_600, packets: 10)
        rig.engine.audioDeactivated()
        readings(rig, for: 0.4, samples: 1_600, packets: 10)
        #expect(readySent(rig) == 0, "never ready while the audio is being taken away")
        var started: Bool?
        rig.engine.startAudioDirectly { started = $0 }          // GraineCalls' half-second rescue
        #expect(started == true)
        readings(rig, for: 0.2, samples: 1_600, packets: 10)
        #expect(readySent(rig) == 0, "the stretch counts from the rescue, never from before it")
        readings(rig, for: 0.2, samples: 1_600, packets: 10)
        #expect(readySent(rig) == 1)
        #expect(events(rig) == ["deactivated_live", "rescued", "ready"])
    }

    @Test func audioLostAfterReadyIsSaidReadyAgainOnceItPlaysAgain() {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.level.samplesReceived = 0
        readings(rig, for: 1, samples: 1_600, packets: 10)
        #expect(readySent(rig) == 1)
        rig.engine.audioDeactivated()                           // a late deactivation after the greeting went
        readings(rig, for: 0.4, samples: 0, packets: 10)
        rig.engine.startAudioDirectly { _ in }
        readings(rig, for: 0.6, samples: 1_600, packets: 10)
        #expect(readySent(rig) == 2, "said again: the server logs how much of what it sent may not have been heard")
        #expect(events(rig) == ["ready", "deactivated_live", "rescued", "ready"])
        #expect(JSON.string(audioRows(rig).last?["reason"]) == "deactivated")
        readings(rig, for: 2, samples: 1_600, packets: 10)
        #expect(readySent(rig) == 2, "once per loss")
    }

    @Test func aStallAfterReadyIsSaidReadyAgainWithItsCauseOnceTheRestartPlays() {
        let rig = heard()
        #expect(readySent(rig) == 1)
        rig.audio.cause = "unit_failed"
        readings(rig, for: 2.2, samples: 0, packets: 10)
        #expect(rig.audio.steps.filter { $0 == "restart" }.count == 1)
        readings(rig, for: 0.6, samples: 1_600, packets: 10)
        #expect(readySent(rig) == 2)
        #expect(events(rig) == ["ready", "playout_restarted", "ready"])
        #expect(JSON.string(audioRows(rig).last?["reason"]) == "unit_failed")
    }

    @Test func everyBodySentForTheCallCarriesThePhonesPromise() throws {
        var mint = try #require(try JSONSerialization.jsonObject(with: DirectFixture.body(sessionId: "s-1", callId: "call_1234567890")) as? [String: Any])
        mint["audio_ready_signal"] = true
        let parts = try #require(RtcMintBodyParts(try JSONSerialization.data(withJSONObject: mint)))
        #expect(parts.audioReadySignal)
        #expect(parts.identityKey == RtcMintBodyParts(DirectFixture.body(sessionId: "s-1", callId: "call_1234567890"))?.identityKey,
                "the same customer: the promise is the call's, not who it is for")
        let grantOnly = try #require(try JSONSerialization.jsonObject(with: parts.grantOnlyBody(callId: "call_next9")) as? [String: Any])
        #expect(grantOnly["audio_ready_signal"] as? Bool == true && grantOnly["grant_only"] as? Bool == true)
        let direct = try #require(try JSONSerialization.jsonObject(with: parts.directBody(grant: "v1.g.s")) as? [String: Any])
        #expect(Set(direct.keys) == ["grant", "session_id", "variables", "audio_ready_signal"])
        let without = try #require(RtcMintBodyParts(DirectFixture.body()))
        let plain = try #require(try JSONSerialization.jsonObject(with: without.directBody(grant: "g")) as? [String: Any])
        #expect(!without.audioReadySignal && plain["audio_ready_signal"] == nil, "a body without it promises nothing")
    }
}
