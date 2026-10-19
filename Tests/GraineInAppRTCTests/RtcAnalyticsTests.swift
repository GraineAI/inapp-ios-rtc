import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * THE CALL'S ANALYTICS ROWS ON WEBRTC (contract v1, GraineCallTelemetry): what
 * the engine measures and when it says it, on the call's own control channel —
 * the connect row at media (cold, prepared, the direct mint), the voice row
 * when the agent is first heard, a recovery row each time the connection heals,
 * the quality row before the BYE or at theirs, the media row when an answered
 * call gets no audio path. Every row waits for the channel to join and is
 * dropped if it never does; none carries an id or an identity.
 */

/// The analytics rows a call's control channel sent: name, detail, data and the frame.
private func rows(_ rig: EngineRig) -> [(name: String, detail: String, data: [String: Any], text: String)] {
    rig.sockets.control.flatMap(\.sent).compactMap { text in
        guard let object = JSON.object(from: text), JSON.string(object["type"]) == "app_event",
              let event = object["event"] as? [String: Any], event["telemetry"] as? Bool == true, event["quiet"] as? Bool == true else { return nil }
        return (JSON.string(event["name"]), JSON.string(event["detail"]), event["data"] as? [String: Any] ?? [:], text)
    }
}

private func join(_ rig: EngineRig) {
    rig.sockets.control.last?.deliver(#"{"type":"control_ready"}"#)
}

private let transportRow = GraineCallTelemetry.frame("transport", ["transport": "rtc", "requested": "auto"])!

@Suite struct RtcAnalyticsTests {
    // MARK: - connect

    @Test func aColdCallsConnectRowSaysWhereTheTapsWaitWentOnceItsChannelJoins() throws {
        let rig = EngineRig()
        rig.minting.hold = true
        rig.media.offerResult = nil
        rig.sbc.holdFinal = true
        rig.sbc.sendTrying = false              // any reply unanswered for 0.5 s is a stuck dial; this one is only slow
        rig.sbc.challenge = false
        rig.engine.transportRow = transportRow
        rig.engine.prepare()                    // the tap: a cold call is prepared and begun together
        rig.engine.begin()
        rig.clock.advance(0.64)
        rig.minting.release()                   // minted on the web route: 640 ms
        rig.clock.advance(0.12)
        rig.media.finishOffer()                 // gathered: 120 ms
        rig.clock.advance(0.18)
        rig.openSip()                           // registered 300 ms after its socket was asked for
        rig.clock.advance(0.1)
        rig.engine.audioActivated()             // the INVITE, 1040 ms after the tap
        rig.clock.advance(0.605)
        rig.sbc.releaseFinal()                  // answered 605 ms later
        rig.clock.advance(0.03)
        rig.media.ice(.connected)               // media 30 ms after the answer
        #expect(rig.names == ["ready", "connected"])
        let control = try #require(rig.sockets.control.first)
        #expect(control.sent.isEmpty, "nothing until the channel joins")
        join(rig)
        #expect(control.sent == [
            transportRow,
            #"{"type":"app_event","event":{"name":"connect","detail":"cold · 1.6s (setup 1.0s, answer 0.6s)","quiet":true,"telemetry":true,"data":{"mode":"cold","warm":false,"total_ms":1645,"setup_ms":1040,"dial_ms":605,"mint_ms":640,"mint_route":"web","gather_ms":120,"register_ms":300,"redials":0,"ice_ms":30}}}"#,
        ], "the transport row its dialler wrote, then the connect row: total = setup + dial")
    }

    @Test func aCallPreparedAheadSaysPreparedWithThePreparationsOwnTimesAndItsAge() throws {
        let d = DirectRig()
        d.warm()
        let rig = d.place()
        d.gateway.holding = [.direct]
        rig.media.offerResult = nil
        rig.sbc.holdFinal = true
        rig.sbc.sendTrying = false
        rig.sbc.challenge = false
        rig.engine.prepare()                    // prepareCall, long before the tap
        d.clock.advance(0.188)
        d.gateway.release(.direct)              // minted at the gateway: 188 ms
        d.clock.advance(0.041)
        rig.media.finishOffer()                 // gathered: 41 ms
        d.clock.advance(0.889)
        rig.openSip()                           // registered: 930 ms
        #expect(rig.names == ["ready"])
        rig.engine.preparedAhead = true
        rig.engine.transportRow = transportRow
        d.clock.advance(73.482)
        rig.engine.begin()                      // the tap, 74.6 s after the preparation began
        d.clock.advance(0.096)
        rig.engine.audioActivated()             // the INVITE: 96 ms of setup
        d.clock.advance(0.716)
        rig.sbc.releaseFinal()                  // answered: 716 ms
        d.clock.advance(0.038)
        rig.media.ice(.connected)               // media: 38 ms
        join(rig)
        let connect = try #require(rows(rig).first { $0.name == "connect" })
        #expect(connect.text == #"{"type":"app_event","event":{"name":"connect","detail":"prepared · 0.8s (setup 0.1s, answer 0.7s)","quiet":true,"telemetry":true,"data":{"mode":"prepared","warm":true,"total_ms":812,"setup_ms":96,"dial_ms":716,"mint_ms":188,"mint_route":"direct","gather_ms":41,"register_ms":930,"redials":0,"prepared_age_s":75,"ice_ms":38}}}"#,
                "all twelve keys — as the contract's own prepared case")
        #expect(connect.data.count == GraineCallTelemetry.maxKeys)
    }

    @Test func preparedAheadButStillMintingAtTheTapIsCold() throws {
        let rig = EngineRig()
        rig.minting.hold = true
        rig.engine.preparedAhead = true
        rig.engine.prepare()
        rig.clock.advance(1)
        rig.engine.begin()                      // tapped before it was set up and registered
        rig.minting.release()
        rig.openSip()
        rig.engine.audioActivated()
        rig.media.ice(.connected)
        join(rig)
        let connect = try #require(rows(rig).first { $0.name == "connect" })
        #expect(connect.data["mode"] as? String == "cold" && connect.data["warm"] as? Bool == false)
        #expect(connect.data["prepared_age_s"] == nil)
        #expect(connect.data["mint_ms"] as? Int == 1000, "its mint, inside the setup")
        #expect(rows(rig).filter { $0.name == "connect" }.count == 1, "once")
    }

    // MARK: - voice

    @Test func theVoiceRowOnceWhenTheAgentIsFirstHeardWithItsCodecAndPath() throws {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.level.packetsReceived = 12   // audio, but not yet a voice
        rig.media.level.audioLevel = 0.001
        rig.media.level.codec = "audio/opus"
        rig.media.level.clockRate = 48_000
        rig.media.level.candidate = "relay"
        rig.clock.advance(0.2)
        #expect(!rows(rig).contains { $0.name == "voice" })
        rig.media.level.audioLevel = 0.3
        rig.clock.advance(0.2)
        rig.clock.advance(2)                    // still talking: no second row
        let voice = rows(rig).filter { $0.name == "voice" }
        #expect(voice.count == 1)
        #expect(voice.first?.text == #"{"type":"app_event","event":{"name":"voice","detail":"agent's voice 0.4s after the tap (0.4s after the answer)","quiet":true,"telemetry":true,"data":{"tap_to_voice_ms":400,"answer_to_voice_ms":400,"first_audio_ms":200,"codec":"opus/48000","candidate":"relay"}}}"#)
    }

    // MARK: - recovery

    @Test func aRedialThatGetsThroughSaysHowLongTheTroubleLasted() throws {
        let rig = EngineRig()
        rig.sbc.challenge = false
        rig.sbc.inviteFinal = nil                  // 100 Trying, then nothing
        rig.ready()
        rig.engine.audioActivated()
        rig.clock.advance(0.5)                     // stuck: cancelled, a fresh connection
        rig.sbc.inviteFinal = 200
        rig.clock.advance(0.7)
        rig.openSip()                              // dialled again, answered
        rig.clock.advance(0.11)
        rig.media.ice(.connected)
        join(rig)
        let names = rows(rig).map(\.name)
        #expect(names == ["connect", "recovery"])
        #expect(rows(rig).first?.data["redials"] as? Int == 1)
        #expect(rows(rig).last?.text == #"{"type":"app_event","event":{"name":"recovery","detail":"redial after 0.8s","quiet":true,"telemetry":true,"data":{"what":"redial","after_ms":810}}}"#)
    }

    @Test func aRestartedMediaPathIsARecoveryOneBackOnItsOwnIsNot() throws {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.ice(.disconnected)
        rig.clock.advance(1)
        rig.media.ice(.connected)                  // back on its own
        #expect(!rows(rig).contains { $0.name == "recovery" })
        rig.media.ice(.disconnected)
        rig.clock.advance(3)                       // restarted
        #expect(rig.media.reoffers == [true])
        rig.clock.advance(0.1)
        rig.media.ice(.connected)
        let recovery = rows(rig).filter { $0.name == "recovery" }
        #expect(recovery.map(\.text) == [#"{"type":"app_event","event":{"name":"recovery","detail":"ice restart after 3.1s","quiet":true,"telemetry":true,"data":{"what":"ice_restart","after_ms":3100}}}"#])
    }

    @Test func aSipSocketReplacedBeforeTheDialWaitsForTheChannel() throws {
        let rig = EngineRig()
        rig.ready()
        rig.sockets.sip.last?.serverClose(1006, "gone")
        rig.clock.advance(0.25)
        rig.openSip()                              // a fresh connection, registered
        #expect(rows(rig).isEmpty, "queued: the channel has not joined")
        rig.engine.audioActivated()
        rig.media.ice(.connected)
        join(rig)
        #expect(rows(rig).map(\.name) == ["recovery", "connect"], "kept in order until it joined")
        #expect(rows(rig).first?.data["what"] as? String == "socket_replaced")
        #expect(rows(rig).first?.data["after_ms"] as? Int == 250)
    }

    @Test func aSipSocketReplacedUnderALiveCall() throws {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.sockets.sip.last?.serverClose(1006, "gone")
        rig.clock.advance(2)                       // reconnected (JsSIP's recovery)…
        #expect(rig.sockets.sip.count == 2)
        rig.clock.advance(0.35)
        rig.openSip()                              // …and open
        let recovery = rows(rig).filter { $0.name == "recovery" }
        #expect(recovery.map(\.detail) == ["socket replaced after 2.4s"])
        #expect(recovery.first?.data["after_ms"] as? Int == 2350)
        #expect(rig.names == ["ready", "connected"], "the call went on")
    }

    // MARK: - quality

    @Test func theQualityRowGoesBeforeTheByeWhenWeHangUp() throws {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.media.level.packetsReceived = 1_000
        rig.media.level.packetsLost = 3
        rig.media.level.jitter = 0.012
        rig.media.level.roundTrip = 0.048
        rig.clock.advance(40)
        rig.media.level.jitter = 0.04              // one spike
        rig.clock.advance(0.2)
        rig.media.level.jitter = 0.012
        rig.clock.advance(23.8)
        var order: [String] = []
        let control = try #require(rig.sockets.control.last)
        control.onSend = { text in order.append(text.contains(#""name":"quality""#) ? "quality" : "control") }
        let sip = try #require(rig.sockets.sip.last)
        let server = sip.onSend
        sip.onSend = { text in
            if SipParser.parse(text)?.method == "BYE" { order.append("BYE") }
            server?(text)
        }
        rig.engine.hangUp()
        #expect(order == ["quality", "BYE"], "before the BYE, on the channel still open")
        let quality = rows(rig).filter { $0.name == "quality" }
        #expect(quality.map(\.text) == [#"{"type":"app_event","event":{"name":"quality","detail":"64s · loss 0.3% · jitter 12 ms","quiet":true,"telemetry":true,"data":{"duration_s":64,"loss_pct":0.3,"jitter_avg_ms":12,"jitter_max_ms":40,"rtt_avg_ms":48}}}"#])
    }

    @Test func atTheirByeTheQualityRowOnce() throws {
        let rig = EngineRig()
        rig.live()
        join(rig)
        rig.clock.advance(12)
        let invite = try #require(rig.invites.last)
        rig.sockets.sip.last?.deliver([
            "BYE sip:c@h.invalid SIP/2.0", "Via: SIP/2.0/WSS 198.51.100.7;branch=z9hG4bKbye",
            "From: <sip:app-1@sbc.example.test>;tag=cByBmmry4gpBj", "To: \(invite.header("From")!)",
            "Call-ID: \(invite.callId!)", "CSeq: 1 BYE", "Content-Length: 0", "", "",
        ].joined(separator: "\r\n"))
        #expect(rig.names.last == "ended(remote)")
        rig.engine.hangUp()
        let quality = rows(rig).filter { $0.name == "quality" }
        #expect(quality.count == 1)
        #expect(quality.first?.data["duration_s"] as? Int == 12)
    }

    @Test func aCallThatNeverHadMediaHasNoQualityRow() {
        let fellBack = EngineRig()
        fellBack.minting.outcome = .unreachable("offline")
        fellBack.ready()
        join(fellBack)
        let dialling = EngineRig()
        dialling.sbc.inviteFinal = nil
        dialling.ready()
        join(dialling)
        dialling.engine.audioActivated()
        dialling.engine.hangUp()
        #expect(!rows(fellBack).contains { $0.name == "quality" })
        #expect(rows(dialling).isEmpty)
    }

    // MARK: - media

    @Test func answeredAndNoAudioPathSaysWhyBeforeTheChannelCloses() throws {
        let failed = EngineRig(budget: 60)
        failed.ready()
        failed.engine.audioActivated()
        join(failed)
        failed.media.ice(.failed)
        #expect(failed.names.last == "unreachable(ice_timeout)", "the fallback's reason is unchanged")
        #expect(rows(failed).map(\.text) == [#"{"type":"app_event","event":{"name":"media","detail":"no audio path (ice_failed)","quiet":true,"telemetry":true,"data":{"reason":"ice_failed","transport":"rtc"}}}"#])
        #expect(failed.sockets.control.first?.closedByClient == true, "then it closes")

        let late = EngineRig(budget: 60)
        late.ready()
        late.engine.audioActivated()
        join(late)
        late.clock.advance(8.1)
        #expect(rows(late).map(\.detail) == ["no audio path (ice_timeout)"])

        let notJoined = EngineRig(budget: 60)
        notJoined.ready()
        notJoined.engine.audioActivated()
        notJoined.media.ice(.failed)
        #expect(rows(notJoined).isEmpty, "a channel that never joined sends nothing")
    }

    // MARK: - the channel, ids, keys

    @Test func aChannelThatNeverJoinsDropsEveryRow() throws {
        let rig = EngineRig()
        rig.engine.transportRow = transportRow
        rig.live()
        rig.media.level.audioLevel = 0.3
        rig.media.level.packetsReceived = 10
        rig.clock.advance(5)
        rig.engine.hangUp()
        let control = try #require(rig.sockets.control.first)
        #expect(control.sent.isEmpty)
        #expect(control.closedByClient)
    }

    @Test func noRowCarriesAnIdOrAnIdentityOrMoreThanTwelveKeys() throws {
        let d = DirectRig()
        d.warm()
        let rig = d.place()
        rig.engine.transportRow = transportRow
        rig.live()
        join(rig)
        rig.media.level = RtcInboundAudio(audioLevel: 0.3, totalAudioEnergy: 1, bytesReceived: 9_000, packetsReceived: 80, packetsLost: 1,
                                          jitter: 0.01, codec: "audio/PCMU", path: "srflx → host", roundTrip: 0.05, clockRate: 8_000, candidate: "srflx")
        rig.clock.advance(1)
        rig.media.ice(.disconnected)
        rig.clock.advance(3.2)
        rig.media.ice(.connected)
        rig.engine.hangUp()
        let sent = rows(rig)
        #expect(sent.map(\.name) == ["transport", "connect", "voice", "recovery", "quality"])
        let secrets = [rig.engine.sessionId, "pk_test_rig", "customer-1", "call_next1", "web-0123456789abcdef", "agent-webcall-1",
                       "817361cd", "sbc.example.test", "208fd2fd", "198.51.100.7", "v1.grant-", "Asia/Kolkata", "card_blocked"]
        for row in sent {
            for secret in secrets { #expect(!row.text.contains(secret), "\(row.name) carries \(secret)") }
            #expect(row.data.count <= GraineCallTelemetry.maxKeys)
            let allowed = Set(GraineCallTelemetry.rows[row.name]?.map(\.key) ?? [])
            #expect(Set(row.data.keys).isSubset(of: allowed), "\(row.name): only its own keys")
        }
    }
}
