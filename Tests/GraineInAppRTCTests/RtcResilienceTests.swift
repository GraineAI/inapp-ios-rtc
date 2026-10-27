import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * WEBRTC STAYS UP ON A WEAK NETWORK (0.14.4) — the voice bar's rules
 * (lib/rtc-resilience.ts, lib/rtc-dial.ts, lib/rtc-media-recovery.ts), as
 * ported: the pure rules, the dials end to end, the recovery's clock on a
 * stand-in for the call, and the media path end to end on the scripted SBC.
 * What it restarts, when, and what it never does: restart into no network,
 * restart after a hang-up, start a second call for a restart, or end a call
 * because a restart was refused.
 */

// MARK: - The rules

@Suite struct RtcResilienceRuleTests {
    @Test func nothingMeasuredIsAGoodLinkAndTheSlowestReadingSetsThePace() {
        #expect(RtcPace.of() == 1, "nothing measured: every deadline stays at its base")
        #expect(RtcPace.of(registerSeconds: 0.4, probeSeconds: 0.12, roundTripSeconds: 0.06) == 1, "a fast link never shortens anything")
        #expect(RtcPace.of(registerSeconds: 4) == 2, "a 4 s registration: twice a good link's 2 s")
        #expect(RtcPace.of(probeSeconds: 1.2) == 1.5)
        #expect(RtcPace.of(roundTripSeconds: 0.5) == 2)
        #expect(RtcPace.of(registerSeconds: 60, roundTripSeconds: 9) == RtcPace.max, "never past the cap")
        #expect(RtcPace.of(registerSeconds: .nan, probeSeconds: -1, roundTripSeconds: .infinity) == 1, "garbage is not a measurement")
    }

    @Test func mediaDeadlinesGrowWithThePaceAndNeverShrinkBelowTheirBase() {
        #expect(RtcResilience.mediaDeadline(pace: 1) == DialRules.iceConnectDeadline, "8 s on a good link, unchanged")
        #expect(RtcResilience.mediaDeadline(pace: 0.3) == 8)
        #expect(RtcResilience.mediaDeadline(pace: 2) == 16)
        #expect(RtcResilience.mediaDeadline(pace: 2.5) == 20)
        #expect(RtcResilience.mediaHardCap(pace: 1) == 16)
        #expect(RtcResilience.mediaHardCap(pace: 2.5) == 30, "never more than 30 s")
        #expect(RtcResilience.restartWindow(pace: 1) == 6)
        #expect(RtcResilience.restartWindow(pace: 2.5) == 15)
        #expect(RtcResilience.restartHardCap(pace: 1) == 12)
        #expect(RtcResilience.restartHardCap(pace: 2.5) == 24)
        #expect(RtcResilience.earlyRestart(pace: 1) == 2.5)
        #expect(RtcResilience.lostGiveUp(pace: 1) == 15)
        #expect(RtcResilience.lostGiveUp(pace: 2.5) == 30)
        #expect(RtcResilience.restartAfter == 3)
        #expect(RtcResilience.maxRestarts == 2)
    }

    @Test func aSetupStillMakingProgressIsNeverCutUntilItsHardCap() {
        #expect(RtcResilience.setupStep(pathUp: false, progressing: false, elapsed: 7.99, deadline: 8, hardCap: 16) == .wait)
        #expect(RtcResilience.setupStep(pathUp: false, progressing: false, elapsed: 8, deadline: 8, hardCap: 16) == .act)
        #expect(RtcResilience.setupStep(pathUp: false, progressing: true, elapsed: 8, deadline: 8, hardCap: 16) == .wait)
        #expect(RtcResilience.setupStep(pathUp: false, progressing: true, elapsed: 16, deadline: 8, hardCap: 16) == .act)
        #expect(RtcResilience.setupStep(pathUp: true, progressing: false, elapsed: 99, deadline: 8, hardCap: 16) == .up)
    }

    @Test func theFirstRestartAlwaysMayASecondOnlyWhenSomethingChanged() {
        func may(_ restarts: Int, changed: Bool = false, udp: Bool = false, tried: Bool = false, refused: Bool = false) -> Bool {
            RtcResilience.restartPermitted(restarts: restarts, networkChanged: changed, udpBlocked: udp, relayOnlyTried: tried, refused: refused)
        }
        #expect(may(0))
        #expect(!may(1), "the same restart again would fail the same way")
        #expect(may(1, changed: true), "a new network is worth a new gathering")
        #expect(may(1, udp: true), "UDP blocked and the TCP/TLS relays not tried alone")
        #expect(!may(1, udp: true, tried: true))
        #expect(!may(2, changed: true), "never a third")
        #expect(!may(0, refused: true), "a server that refused one refuses the next")
    }

    @Test func progressIsChecksAnsweredBytesInTheHandshakeMovingNeverOurOwnUnansweredChecks() {
        let a = RtcIceReading(pairs: 1, inProgress: 1, requestsSent: 3)
        var b = a
        b.requestsSent = 40
        #expect(!RtcResilience.progressed(from: a, to: b), "checks nobody answers are a blocked path")
        b = a; b.responsesReceived = 1
        #expect(RtcResilience.progressed(from: a, to: b))
        b = a; b.requestsReceived = 1
        #expect(RtcResilience.progressed(from: a, to: b))
        b = a; b.bytesReceived = 600
        #expect(RtcResilience.progressed(from: a, to: b), "a DTLS flight arriving")
        b = a; b.dtlsState = "connecting"
        #expect(RtcResilience.progressed(from: a, to: b))
        #expect(!RtcResilience.progressed(from: nil, to: a), "no earlier reading: no evidence")
        #expect(RtcResilience.nothingInFlight(RtcIceReading()), "no candidate pair at all")
        #expect(RtcResilience.nothingInFlight(RtcIceReading(pairs: 2, failed: 2)), "every pair failed")
        #expect(!RtcResilience.nothingInFlight(a), "a check under way is waited for")
        #expect(!RtcResilience.nothingInFlight(nil), "statistics that could not be read say nothing")
    }

    static let servers = [
        RtcIceServer(urls: ["stun:stun.relay.example.test:80"], username: nil, credential: nil),
        RtcIceServer(urls: ["turn:relay.example.test:80"], username: "u", credential: "c"),
        RtcIceServer(urls: ["turn:relay.example.test:80?transport=tcp", "turns:relay.example.test:443?transport=tcp"], username: "u", credential: "c"),
    ]

    @Test func theRelaysOverTcpAndTlsArePickedOutCredentialsKept() {
        #expect(RtcResilience.tcpTlsRelays(Self.servers) == [
            RtcIceServer(urls: ["turn:relay.example.test:80?transport=tcp", "turns:relay.example.test:443?transport=tcp"], username: "u", credential: "c"),
        ])
        #expect(RtcResilience.tcpTlsRelays([RtcIceServer(urls: ["turn:udp.example.test:3478"], username: nil, credential: nil)]).isEmpty)
    }

    @Test func udpLooksBlockedOnlyWhenNothingCameBackOverItAndATcpOrTlsRelayExists() {
        var g = RtcGathered()
        #expect(!RtcResilience.udpLooksBlocked(g, servers: Self.servers), "nothing gathered at all is another problem")
        g.add("candidate:1 1 udp 2122194688 192.0.2.10 65463 typ host")
        g.add("candidate:2 1 udp 2 203.0.113.9 50000 typ relay raddr 0.0.0.0 rport 0", serverUrl: "turns:relay.example.test:443?transport=tcp")
        #expect(g.relayTls == 1)
        #expect(RtcResilience.udpLooksBlocked(g, servers: Self.servers), "only the TLS relay came back")
        var withSrflx = g
        withSrflx.add("candidate:3 1 udp 1685987071 203.0.113.1 65463 typ srflx raddr 192.0.2.10 rport 65463")
        #expect(!RtcResilience.udpLooksBlocked(withSrflx, servers: Self.servers), "STUN answered over UDP")
        var withUdpRelay = g
        withUdpRelay.add("candidate:4 1 udp 3 203.0.113.9 50001 typ relay", serverUrl: "turn:relay.example.test:80")
        #expect(!RtcResilience.udpLooksBlocked(withUdpRelay, servers: Self.servers), "a relay answered over UDP")
        var unknown = g
        unknown.add("candidate:5 1 udp 3 203.0.113.9 50002 typ relay")
        #expect(unknown.relayUnknown == 1)
        #expect(!RtcResilience.udpLooksBlocked(unknown, servers: Self.servers), "a relay of unknown protocol is never read as UDP blocked")
        var hostOnly = RtcGathered()
        hostOnly.add("candidate:1 1 udp 2122194688 192.0.2.10 65463 typ host")
        #expect(!RtcResilience.udpLooksBlocked(hostOnly, servers: [Self.servers[1]]), "no TCP or TLS relay to move to")
        #expect(RtcResilience.candidateCount("v=0\r\na=candidate:1 1 udp 1 1.2.3.4 5 typ host\r\n") == 1)
        #expect(RtcResilience.candidateCount("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n") == 0)
    }

    @Test func aLinksFailureEarnsAThirdDialAStuckServerKeepsTwoAnd491IsDialledAgain() {
        for cause in ["no_response", SipCauses.connectionError, SipCauses.requestTimeout] {
            #expect(DialRules.verdict(cause: cause, code: nil, dialsSoFar: 2) == .redial, "\(cause): the third dial")
            #expect(DialRules.verdict(cause: cause, code: nil, dialsSoFar: 3) == .fallback, "\(cause): then the socket")
        }
        #expect(DialRules.verdict(cause: "no_answer", code: nil, dialsSoFar: 2) == .fallback)
        #expect(DialRules.verdict(cause: SipCauses.sipFailureCode, code: 503, dialsSoFar: 2) == .fallback)
        // Production, 26 Oct 2026, a +300 ms link: the INVITE with credentials answered 491, and the call went to the socket at once.
        #expect(DialRules.verdict(cause: SipCauses.forCode(491), code: 491, dialsSoFar: 1) == .redial)
        #expect(DialRules.verdict(cause: SipCauses.forCode(491), code: 491, dialsSoFar: 2) == .redial)
        #expect(DialRules.verdict(cause: SipCauses.forCode(491), code: 491, dialsSoFar: 3) == .fallback)
        #expect(DialRules.verdict(cause: SipCauses.forCode(486), code: 486, dialsSoFar: 1) == .fallback, "a 4xx that is an answer is still one")
        #expect(RtcCallEngine.describe(cause: SipCauses.sipFailureCode, code: 491) == "491 Request Pending")
    }

    @Test func theAnswerSeatbeltIsHalfASecondOnAGoodLinkLongerOnlyOnAMeasuredSlowOne() {
        #expect(DialRules.answerAfterHeard(pace: 1) == 0.5)
        #expect(DialRules.answerAfterHeard(pace: 0.2) == 0.5)
        #expect(DialRules.answerAfterHeard(pace: 2) == 1)
        #expect(DialRules.answerAfterHeard(pace: 9) == 1.25, "far short of the 3 s that was withdrawn")
    }

    @Test func theRelayWaitGrowsWithASlowLinkOnlyWhileUdpHasShownNothing() {
        #expect(IceGathering.cap(wantRelay: false, pace: 2.5, sawSrflx: false) == 1.5, "no TURN: as before")
        #expect(IceGathering.cap(wantRelay: true, pace: 1, sawSrflx: false) == 2.5, "a good link: as before")
        #expect(IceGathering.cap(wantRelay: true, pace: 1.6, sawSrflx: false) == 4)
        #expect(IceGathering.cap(wantRelay: true, pace: 2.5, sawSrflx: false) == 5, "twice at most")
        #expect(IceGathering.cap(wantRelay: true, pace: 2.5, sawSrflx: true) == 2.5, "UDP works: the relay is a spare")
    }
}

// MARK: - The dials, end to end

@Suite struct RtcResilienceDialTests {
    @Test func a491IsDialledAgainOnAFreshConnectionNotHandedToTheSocket() {
        let rig = EngineRig()
        rig.sbc.inviteFinal = 491
        rig.ready()
        rig.engine.audioActivated()
        #expect(rig.sockets.sip.count == 2, "a 491 went to the WebSocket at once")
        #expect(!rig.names.contains { $0.hasPrefix("unreachable") })
        rig.sbc.inviteFinal = 200
        rig.openSip()
        rig.media.ice(.connected)
        #expect(rig.names == ["ready", "connected"])
    }

    @Test func aDialHeardAndNotAnsweredKeepsItsTwoDials() throws {
        let rig = EngineRig(budget: 60)
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        rig.clock.advance(4.1)                   // dial 1: nothing back — the link's failure
        rig.openSip()
        let second = try #require(rig.invites.last)
        rig.sockets.sip[1].deliver(ScriptedSbc.reply(second, 100))   // dial 2 heard…
        rig.clock.advance(0.6)                   // …and never answered: a server that may run an agent, no third dial
        #expect(rig.names.last == "unreachable(no_answer)")
        #expect(rig.sockets.sip.count == 2)
    }

    @Test func aThirdDialWhileTheSecondsInviteIsInFlightAndItsLateAnswerIsAckedAndEndedOnItsOwnSocket() throws {
        let rig = EngineRig(budget: 60)
        rig.answerByHand()
        rig.ready()
        rig.engine.audioActivated()
        rig.clock.advance(4.1)                   // dial 1: nothing back
        rig.openSip()
        let dial2 = try #require(rig.invites.last)
        let socket2 = rig.sockets.sip[1]
        rig.clock.advance(4.1)                   // dial 2: nothing back either — a third, on another fresh connection
        #expect(rig.sockets.sip.count == 3)
        socket2.deliver(ScriptedSbc.answer(dial2))   // dial 2's answer turns up late, on its own socket
        #expect(!rig.names.contains("connected"), "the abandoned dial's answer took over the call")
        #expect(socket2.sentMessages.contains { $0.method == "ACK" }, "the late answer was not ACKed")
        #expect(socket2.sentMessages.contains { $0.method == "BYE" }, "the abandoned dial's leg was left up on the server (a second greeting)")
        rig.openSip()
        #expect(rig.invites.count == 3, "the third dial went on its own connection")
    }
}

// MARK: - The recovery's clock

final class FakeRecoveryHost: RtcRecoveryHost {
    var pace = 1.0
    var online = true
    var canReoffer = true
    var udpBlocked = false
    var reading: () -> RtcIceReading? = { RtcIceReading(pairs: 1, inProgress: 1, requestsSent: 3) }
    var sends = true
    private(set) var restarts: [(n: Int, relayOnly: Bool, on: RtcRestartHandlers)] = []
    private(set) var failures: [String] = []
    private(set) var reconnecting: [Bool] = []
    private(set) var recovered: [Int] = []

    func recoveryPace() -> Double { pace }
    func recoveryOnline() -> Bool { online }
    func recoveryCanReoffer() -> Bool { canReoffer }
    func recoveryRestart(_ n: Int, relayOnly: Bool, _ handlers: RtcRestartHandlers) -> Bool {
        guard sends else { return false }
        restarts.append((n, relayOnly, handlers))
        return true
    }
    func recoveryStats(_ done: @escaping (RtcIceReading?) -> Void) { done(reading()) }
    func recoveryUdpBlocked() -> Bool { udpBlocked }
    func recoveryFailed(_ failure: RtcMediaFailure) {
        switch failure {
        case .iceTimeout: failures.append("ice_timeout")
        case .iceFailed: failures.append("ice_failed")
        case .iceDisconnected: failures.append("ice_disconnected")
        }
    }
    func recoveryReconnecting(_ active: Bool) { reconnecting.append(active) }
    func recoveryRecovered(restarts: Int, seconds: Double) { recovered.append(restarts) }
    func recoveryLog(_ line: String) {}
}

@Suite struct RtcMediaRecoveryTests {
    func make(_ configure: (FakeRecoveryHost) -> Void = { _ in }) -> (ManualRtcClock, FakeRecoveryHost, RtcMediaRecovery) {
        let clock = ManualRtcClock()
        let host = FakeRecoveryHost()
        configure(host)
        return (clock, host, RtcMediaRecovery(host: host, clock: clock))
    }

    @Test func aSetupWithNoPathIsRestartedAtItsDeadlineNotBeforeAndNotHandedOver() {
        let (clock, host, r) = make()
        r.answered()
        clock.advance(7.9)
        #expect(host.restarts.isEmpty)
        clock.advance(0.1)
        #expect(host.restarts.count == 1, "no restart at the deadline")
        #expect(host.failures.isEmpty)
        host.restarts[0].on.offer(3)
        host.restarts[0].on.answered()
        clock.advance(1)
        r.pathUp()
        #expect(host.recovered == [1], "the rescue is on the record")
        #expect(host.reconnecting.isEmpty, "a call that never connected is never reconnecting")
        clock.advance(60)
        #expect(host.failures.isEmpty)
    }

    @Test func aSetupStillMakingProgressIsNeverCutUntilItsHardCap() {
        var bytes = 0
        let (clock, host, r) = make { h in h.reading = { bytes += 300; return RtcIceReading(pairs: 1, inProgress: 1, requestsSent: 3, bytesReceived: bytes) } }
        r.answered()
        clock.advance(12)
        #expect(host.restarts.isEmpty, "a handshake still moving was restarted")
        clock.advance(4)
        #expect(host.restarts.count == 1, "progress held it past the hard cap")
    }

    @Test func aRefusedRestartHandsOverNeverRestartsAgainAndNeverBeforeTheDeadline() {
        let (clock, host, r) = make { h in h.reading = { RtcIceReading() } }   // nothing in flight: the early restart
        r.answered()
        clock.advance(2.5)
        #expect(host.restarts.count == 1, "nothing in flight: restarted early")
        host.restarts[0].on.refused("488")
        #expect(host.failures.isEmpty, "handed over before the deadline it had before")
        clock.advance(5.4)
        #expect(host.failures.isEmpty)
        clock.advance(0.2)
        #expect(host.failures == ["ice_timeout"])
        #expect(r.refused)
        clock.advance(60)
        #expect(host.restarts.count == 1)
    }

    @Test func aSecondRestartWhenTheNetworkChangedSinceTheFirstAndOnlyThen() {
        let (clock, host, r) = make()
        r.answered()
        clock.advance(8)
        host.restarts[0].on.answered()
        clock.advance(6)
        #expect(host.restarts.count == 1, "nothing changed: no second restart")
        #expect(host.failures == ["ice_timeout"])

        let (clock2, host2, r2) = make()
        r2.answered()
        clock2.advance(8)
        host2.restarts[0].on.answered()
        r2.networkChanged(online: true)
        clock2.advance(6)
        #expect(host2.restarts.count == 2, "a new network earned a new gathering")
        #expect(host2.failures.isEmpty)
    }

    @Test func udpBlockedGathersOnlyTheTcpAndTlsRelaysAndTurnOnlyDoesNotStick() {
        let (clock, host, r) = make { h in h.udpBlocked = true }
        r.answered()
        clock.advance(8)
        #expect(host.restarts.first?.relayOnly == true)
        host.restarts[0].on.answered()
        host.udpBlocked = false                    // the engine forgets UDP evidence on a network change
        r.networkChanged(online: true)
        clock.advance(6)
        #expect(host.restarts.count == 2)
        #expect(host.restarts[1].relayOnly == false, "the new network was gathered on as if it still blocked UDP")
    }

    @Test func noRestartIntoNoNetworkNorIntoASocketThatIsDown() {
        let (clock, host, r) = make { h in h.online = false }
        r.answered()
        clock.advance(10)
        #expect(host.restarts.isEmpty, "a re-offer into no network")
        host.online = true
        host.canReoffer = false
        clock.advance(1)
        #expect(host.restarts.isEmpty, "into a socket that is down")
        host.canReoffer = true
        clock.advance(1)
        #expect(host.restarts.count == 1)
    }

    @Test func aLostPathIsReconnectingRestarted3SecondsInAndBack() {
        let (clock, host, r) = make()
        r.answered()
        r.pathUp()
        r.pathLost(failed: false)
        #expect(host.reconnecting == [true])
        clock.advance(2.9)
        #expect(host.restarts.isEmpty, "a blip ICE heals by itself got a restart")
        clock.advance(0.1)
        #expect(host.restarts.count == 1)
        host.restarts[0].on.answered()
        r.pathUp()
        #expect(host.reconnecting == [true, false])
        #expect(host.recovered == [1])
    }

    @Test func aFailedPathRestartsAtOnce() {
        let (_, host, r) = make()
        r.answered()
        r.pathUp()
        r.pathLost(failed: true)
        #expect(host.restarts.count == 1, "no timer between the failure and its restart")
    }

    @Test func offlineTimeIsNotCountedAndTheNetworksReturnGetsAMomentToHealFirst() {
        let (clock, host, r) = make()
        r.answered()
        r.pathUp()
        host.online = false
        r.networkChanged(online: false)
        r.pathLost(failed: false)
        clock.advance(20)
        #expect(host.restarts.isEmpty)
        #expect(host.failures.isEmpty, "time offline held against the path")
        host.online = true
        r.networkChanged(online: true)
        clock.advance(1.9)
        #expect(host.restarts.isEmpty)
        clock.advance(0.1)
        #expect(host.restarts.count == 1)
    }

    @Test func offlineTooLongIsDropped() {
        let (clock, host, r) = make { h in h.online = false }
        r.answered()
        r.pathUp()
        r.pathLost(failed: false)
        clock.advance(30)
        #expect(host.failures == ["ice_disconnected"])
        #expect(host.reconnecting == [true, false])
    }

    @Test func aRefusedRestartMidCallDoesNotEndTheCallTheGiveUpDecides() {
        let (clock, host, r) = make()
        r.answered()
        r.pathUp()
        r.pathLost(failed: false)
        clock.advance(3)
        host.restarts[0].on.refused("488")
        #expect(host.failures.isEmpty, "a refused restart ended a call whose old path may still come back")
        clock.advance(11.9)
        #expect(host.failures.isEmpty)
        clock.advance(0.2)
        #expect(host.failures == ["ice_disconnected"])
    }

    @Test func theGiveUpNeverCutsAnOpenRestartWindow() {
        let (clock, host, r) = make { h in h.canReoffer = false }   // the call's socket reconnecting
        r.answered()
        r.pathUp()
        r.pathLost(failed: false)
        clock.advance(12)
        host.canReoffer = true
        clock.advance(1)
        #expect(host.restarts.count == 1, "sent at 13 s, when its socket was back")
        clock.advance(3)
        #expect(host.failures.isEmpty, "the give-up at 15 s cut a restart whose window was open")
        clock.advance(3.1)
        #expect(host.failures == ["ice_disconnected"])
    }

    @Test func aRestartRacingAHangUpNothingFiresAfterDispose() {
        let (clock, host, r) = make()
        r.answered()
        r.pathUp()
        r.pathLost(failed: false)
        clock.advance(3)
        #expect(host.restarts.count == 1)
        r.dispose()
        #expect(host.reconnecting == [true, false], "a bar kept reconnecting after the hang-up")
        host.restarts[0].on.refused("408")
        host.restarts[0].on.answered()
        clock.advance(60)
        #expect(host.failures.isEmpty)
        #expect(host.restarts.count == 1)
    }

    @Test func aSlowLinksDeadlineIsLonger() {
        let (clock, host, r) = make { h in h.pace = 2 }
        r.answered()
        clock.advance(8)
        #expect(host.restarts.isEmpty, "a 3G link held to a good link's deadline")
        clock.advance(8)
        #expect(host.restarts.count == 1)
    }
}

// MARK: - The media path, end to end

@Suite struct RtcResilienceEngineTests {
    var reinvites: (EngineRig) -> [SipMessage] = { rig in rig.sbc.received.filter { $0.method == "INVITE" && $0.toTag != nil } }

    @Test func anAnsweredCallWithNoPathIsRestartedInItsOwnCallAndARefusalAtTheDeadlineHandsItOver() throws {
        let rig = EngineRig(budget: 60)
        rig.sbc.reinviteFinal = 488
        rig.ready()
        rig.engine.audioActivated()
        rig.media.ice(.checking)
        rig.clock.advance(7.9)
        #expect(rig.media.reoffers.isEmpty)
        rig.clock.advance(0.1)
        #expect(rig.media.reoffers == [true])
        #expect(reinvites(rig).count == 1, "inside the answered dialog")
        #expect(rig.invites.count == 2, "no new call: the dial's two INVITEs (challenged, then authorised) and nothing else")
        // Refused at the deadline: no more restarts, and the deadline has passed — the WebSocket now, the leg ended.
        #expect(rig.names.last == "unreachable(ice_timeout)")
        rig.clock.advance(30)
        #expect(rig.media.reoffers == [true], "a server that refused was asked again")
    }

    @Test func aRestartRefusedMidCallNeverEndsTheCallTheGiveUpDecides() {
        let rig = EngineRig()
        rig.sbc.reinviteFinal = 488
        rig.live()
        rig.media.ice(.disconnected)
        rig.clock.advance(3)
        #expect(rig.media.reoffers == [true])
        #expect(!rig.names.contains("ended(dropped)"), "a refused restart ended a call whose old path may still come back")
        rig.media.ice(.connected)               // and it does
        #expect(rig.reconnecting == ["reconnecting(true)", "reconnecting(false)"])
        rig.clock.advance(30)
        #expect(!rig.names.contains("ended(dropped)"))
        // Lost again: the far side refuses restarts, so none is tried — dropped at the give-up.
        rig.media.ice(.disconnected)
        rig.clock.advance(14.9)
        #expect(rig.media.reoffers == [true])
        #expect(!rig.names.contains("ended(dropped)"))
        rig.clock.advance(0.2)
        #expect(rig.names.last == "ended(dropped)")
    }

    /// The attempt's 12 s never cut a restart whose window is open — the recovery decides (at most 30 s after the answer).
    @Test func theBudgetNeverCutsARestartInFlight() {
        let rig = EngineRig()
        rig.ready()
        rig.engine.audioActivated()
        rig.media.ice(.checking)
        rig.clock.advance(8)
        #expect(rig.media.reoffers == [true])
        rig.clock.advance(4.5)
        #expect(!rig.names.contains { $0.hasPrefix("unreachable") }, "the 12 s budget cut the restart's window")
        rig.clock.advance(1.6)
        #expect(rig.names.last == "unreachable(ice_timeout)")
    }

    @Test func aRestartThatBringsThePathUpIsARecoveryOnTheRecordAndNothingIsSaidTwice() throws {
        let rig = EngineRig()
        rig.live()
        let control = try #require(rig.sockets.control.first)
        control.open()
        control.deliver(#"{"type":"control_ready"}"#)
        // The phone's audio plays — steadily, for RtcCallEngine.readyStableSeconds: the agent is told once.
        rig.media.level.samplesReceived = 100
        rig.clock.advance(0.2)
        rig.media.level.samplesReceived = 900
        rig.clock.advance(0.2)
        rig.media.level.samplesReceived = 1700
        rig.clock.advance(0.2)
        let readyFrames = { control.sent.filter { $0 == GraineRtcSignal.audioReady }.count }
        #expect(readyFrames() == 1)
        rig.media.ice(.disconnected)
        rig.clock.advance(3.1)
        #expect(rig.media.reoffers == [true])
        rig.media.ice(.connected)
        rig.media.level.samplesReceived = 2500
        rig.clock.advance(1)
        #expect(readyFrames() == 1, "a restart said the audio was ready again")
        #expect(rig.audio.steps.filter { $0 == "begins" }.count == 1, "a restart began the call's audio again")
        #expect(control.sent.contains { $0.contains("\"ice_restart\"") }, "the rescue is not on the record")
        #expect(rig.invites.count == 2, "a restart dialled a new call")
    }

    @Test func aLostPathIsNeverRestartedIntoNoNetworkAndIsRestartedWhenItReturns() {
        let rig = EngineRig()
        rig.live()
        rig.network.set(false)
        rig.media.ice(.disconnected)
        rig.clock.advance(20)
        #expect(rig.media.reoffers.isEmpty, "a re-offer went into no network")
        #expect(!rig.names.contains("ended(dropped)"), "time offline was counted against the path")
        rig.network.set(true)
        rig.clock.advance(2.1)
        #expect(rig.media.reoffers == [true])
        #expect(rig.media.forgets >= 2, "the last network's word on UDP was kept")
    }

    @Test func aRestartRacingAHangUpDoesNothingAfterTheEnd() {
        let rig = EngineRig()
        rig.sbc.holdReinvite = true
        rig.live()
        rig.media.ice(.disconnected)
        rig.clock.advance(3)
        #expect(rig.media.reoffers == [true], "the restart is out")
        let before = rig.events.count
        rig.engine.hangUp()
        rig.sbc.releaseReinvite()                // its answer arrives after the hang-up
        rig.clock.advance(60)
        #expect(rig.events.count == before, "the call said something after the hang-up")
        #expect(rig.media.reoffers == [true], "a second restart after the hang-up")
        #expect(rig.media.appliedAnswers.count == 1, "the late answer was applied to a call that is over")
        #expect(rig.media.closed)
    }

    @Test func aSlowRegistrationGivesTheMediaALongerDeadline() {
        let rig = EngineRig(budget: 60)
        rig.engine.prepare()
        rig.clock.advance(4)                     // the socket and the REGISTER take 4 s: pace 2
        rig.openSip()
        rig.engine.begin()
        rig.engine.audioActivated()
        rig.media.ice(.checking)
        rig.clock.advance(8)
        #expect(rig.media.reoffers.isEmpty, "a slow link held to a good link's 8 s")
        rig.clock.advance(8)
        #expect(rig.media.reoffers == [true])
    }
}

// MARK: - The redial: never into no network, on the relays alone when UDP looked blocked

@Suite struct RtcRedialTests {
    @Test func aRedialWaitsForTheNetworkAndNeverFollowsAHangUp() {
        let rig = EngineRig(budget: 60)
        rig.sbc.inviteFinal = nil
        rig.sbc.sendTrying = false
        rig.sbc.challenge = false
        rig.ready()
        rig.engine.audioActivated()
        rig.network.set(false)
        rig.clock.advance(4.1)                   // nothing back: the link's failure, in no network
        #expect(rig.sockets.sip.count == 1, "a redial went into no network")
        rig.engine.hangUp()
        rig.network.set(true)
        rig.clock.advance(20)
        #expect(rig.sockets.sip.count == 1, "a redial followed the hang-up")

        let back = EngineRig(budget: 60)
        back.sbc.inviteFinal = nil
        back.sbc.sendTrying = false
        back.sbc.challenge = false
        back.ready()
        back.engine.audioActivated()
        back.network.set(false)
        back.clock.advance(4.1)
        #expect(back.sockets.sip.count == 1)
        back.network.set(true)
        #expect(back.sockets.sip.count == 2, "the network came back and nothing was dialled")
    }

    @Test func udpThatLookedBlockedTheNextDialGathersOnlyTheTcpAndTlsRelays() {
        let rig = EngineRig(budget: 60)
        var credential = MintFixture.credential
        credential.iceServers = RtcResilienceRuleTests.servers
        rig.minting.outcome = .credential(credential)
        rig.sbc.inviteFinal = nil
        rig.sbc.sendTrying = false
        rig.sbc.challenge = false
        rig.ready()
        rig.media.gathered.add("candidate:1 1 udp 2122194688 192.0.2.10 65463 typ host")
        rig.media.gathered.add("candidate:2 1 udp 2 203.0.113.9 50000 typ relay", serverUrl: "turns:relay.example.test:443?transport=tcp")
        rig.engine.audioActivated()
        rig.clock.advance(4.1)                   // nothing back: a fresh connection
        #expect(rig.media.serverChanges.count == 1)
        #expect(rig.media.serverChanges.first?.relayOnly == true)
        #expect(rig.media.serverChanges.first?.servers == RtcResilience.tcpTlsRelays(RtcResilienceRuleTests.servers))
        #expect(rig.media.reoffers == [true], "a new offer, gathered on the relays alone, before the INVITE")
    }
}
