import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * A LEG PREPARED AHEAD OF ITS DIAL — a call the app prepared before the tap,
 * or a ring's: what it tells whoever prepared it (ready, how long and by which
 * road; lost) without taking the events kept for the call that dials it; the
 * attempt's twelve seconds counted from the dial; and a ring's grant taken
 * from its own mint's answer.
 */

@Suite struct RtcPreparedCallTests {
    @Test func aPreparedLegSaysWhenItIsReadyAndByWhichRoad() throws {
        let web = EngineRig()
        var reports: [GraineRtcPreparedState] = []
        web.engine.onPrepared = { reports.append($0) }
        web.engine.prepare()
        web.openSip()
        guard case let .ready(milliseconds, direct)? = reports.first, reports.count == 1 else {
            Issue.record("no ready report: \(reports)")
            return
        }
        #expect(!direct, "minted on the web route")
        #expect(milliseconds >= 0)
        #expect(web.names == ["ready"], "the events stay the call's")

        let d = DirectRig()
        d.warm()
        let gateway = d.place()
        var direct2: [GraineRtcPreparedState] = []
        gateway.engine.onPrepared = { direct2.append($0) }
        gateway.engine.prepare()
        gateway.openSip()
        #expect(direct2.count == 1)
        if case let .ready(_, viaGateway)? = direct2.first { #expect(viaGateway, "minted at the gateway") }
    }

    @Test func aPreparedLegSaysWhenItIsLost() {
        let refused = EngineRig()
        refused.sbc.registerReply = 403
        var registration: [GraineRtcPreparedState] = []
        refused.engine.onPrepared = { registration.append($0) }
        refused.engine.prepare()
        refused.openSip()
        #expect(registration == [.lost], "its registration refused")

        let dropped = EngineRig()
        var socket: [GraineRtcPreparedState] = []
        dropped.engine.onPrepared = { socket.append($0) }
        dropped.engine.prepare()
        dropped.openSip()
        dropped.sockets.sip.last?.serverClose(1006, "gone")
        #expect(socket.count == 2 && socket.last == .lost, "its socket dropped while it waited for the tap")

        let gate = EngineRig()
        gate.minting.outcome = .refused(status: 402, code: "insufficient_credits", message: "No credit.")
        var mint: [GraineRtcPreparedState] = []
        gate.engine.onPrepared = { mint.append($0) }
        gate.engine.prepare()
        #expect(mint == [.lost], "its mint refused")

        let released = EngineRig()
        var hungUp: [GraineRtcPreparedState] = []
        released.engine.onPrepared = { hungUp.append($0) }
        released.engine.prepare()
        released.openSip()
        released.engine.hangUp()
        released.clock.advance(30)
        #expect(hungUp.count == 1, "let go by whoever prepared it: nothing more")
    }

    /// The attempt's twelve seconds start when the call is dialled, however long it waited prepared — its registration kept alive.
    @Test func theAttemptsTwelveSecondsStartAtTheDialNotAtPrepare() {
        let rig = EngineRig()
        rig.engine.prepare()
        rig.openSip()
        let registered = rig.sbc.received.filter { $0.method == "REGISTER" }.count
        rig.clock.advance(280)                    // past JsSIP's latest refresh point (150 s + up to 118 s)
        #expect(rig.names == ["ready"], "prepared for minutes: nothing gives up")
        #expect(rig.sbc.received.filter { $0.method == "REGISTER" }.count > registered, "the registration refreshed meanwhile")
        #expect(rig.sockets.control.first?.closedByClient != true && rig.sockets.control.isEmpty, "and no conversation opened")
        rig.engine.begin()
        rig.clock.advance(11.9)
        #expect(rig.names == ["ready"])
        rig.clock.advance(0.2)
        #expect(rig.names == ["ready", "unreachable(error)"], "twelve seconds from the dial")
    }

    /**
     * A PREPARED CALL NEVER TURNS THE MICROPHONE ON (19 Oct: on Android a
     * prepared call recorded from the microphone on the Home screen, before any
     * tap). Preparing puts WebRTC's audio in manual mode, off; it is enabled
     * only when the call dials — CallKit handed the call its audio, or the
     * direct start when it never does — and the INVITE leaves after that, never
     * before. A prepared call let go never enabled it at all.
     */
    @Test func preparingNeverTurnsTheMicrophoneOnOnlyTheDialDoes() throws {
        let rig = EngineRig()
        rig.engine.prepare()
        rig.openSip()
        #expect(rig.names == ["ready"], "minted, gathered, registered")
        rig.clock.advance(200)                    // prepared on the Home screen, minutes before the tap
        #expect(rig.audio.steps == ["begins"], "manual audio, off: nothing records")
        let sip = try #require(rig.sockets.sip.last)
        let server = sip.onSend
        var audioAtInvite: [[String]] = []
        sip.onSend = { text in
            if SipParser.parse(text)?.method == "INVITE" { audioAtInvite.append(rig.audio.steps) }
            server?(text)
        }
        rig.engine.begin()                        // the tap
        rig.clock.advance(1)
        #expect(rig.audio.steps == ["begins"], "the tap alone does not either: the call's audio is CallKit's to hand over")
        #expect(rig.invites.isEmpty)
        rig.engine.audioActivated()               // CallKit's didActivate: the dial
        #expect(rig.audio.steps == ["begins", "activated"])
        #expect(!audioAtInvite.isEmpty && audioAtInvite.allSatisfy { $0 == ["begins", "activated"] }, "enabled first, then the INVITE")

        let released = EngineRig()
        released.engine.prepare()
        released.openSip()
        released.clock.advance(200)
        released.engine.hangUp()                  // let go before any tap: the background, four minutes, another customer
        released.clock.advance(5)
        #expect(released.audio.steps == ["begins", "ends"], "never enabled; its manual mode handed back")
    }

    /// A ring's leg mints on the web route, and that answer carries the ring's grant: one request, not two.
    @Test func aRingKeepsTheGrantItsMintBroughtAndAsksForNoOther() {
        func asked(_ rig: DirectRig, for callId: String) -> Int {
            rig.gateway.sent.filter { $0.kind == .grantOnly && ($0.json?["callId"] as? String) == callId }.count
        }
        let d = DirectRig()
        let ring = d.call(callId: "call_ring000030", rang: true)
        var answer = MintFixture.credential
        answer.direct = DirectFixture.offer(7)
        ring.minting.outcome = .credential(answer)
        ring.ready()
        #expect(d.grant(for: "call_ring000030") == DirectFixture.grant(7), "kept for the ring's id")
        let ownRequests = asked(d, for: "call_ring000030")
        #expect(ownRequests == 0, "no grant request of its own")

        let bare = DirectRig()
        let ring2 = bare.call(callId: "call_ring000031", rang: true)   // an answer with no grant beside the credential
        ring2.ready()
        let fallback = asked(bare, for: "call_ring000031")
        #expect(fallback == 1, "no grant came: asked for on its own, once")
        #expect(bare.grant(for: "call_ring000031") == DirectFixture.grant(1))

        let placed = DirectRig()
        let call = placed.call(callId: "call_own000032")                // the customer's own call
        call.ready()
        let notRung = asked(placed, for: "call_own000032")
        #expect(notRung == 0, "a call that did not ring asks for no grant of its own")
    }
}
