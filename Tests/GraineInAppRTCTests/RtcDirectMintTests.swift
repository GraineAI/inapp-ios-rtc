import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * THE DIRECT MINT, CALL BY CALL, WITH NOTHING REAL: the web route's
 * grant-only mode, the gateway's probe and its direct mint answered as
 * production answers them (or held, or refused), the calls placed one after
 * another on one shared direct mint, the clock moved by hand. A grant names
 * one call: the warm one is asked for the next call's id, which the call the
 * customer places takes; a ringing call's is asked for its own id; any other
 * call takes the web route — whose answer's grant is that call's own. A
 * warm-up with a usable grant sends nothing; each failure costs one short
 * request; a gate's refusal ends the call as the web route's would; "off"
 * rests ten minutes, then the gateway is asked again.
 */

@Suite struct RtcDirectMintTests {
    // MARK: The next call's id

    @Test func theGrantRequestCarriesTheNextCallsId() throws {
        let d = DirectRig()
        d.mint.warm(baseUrl: "https://www.graine.ai/", body: DirectFixture.body(sessionId: ""))
        let ask = try #require(d.gateway.sent.first)
        #expect(ask.url.absoluteString == "https://www.graine.ai/api/embed/rtc-session")
        #expect(ask.json?["grant_only"] as? Bool == true)
        #expect(ask.json?["callId"] as? String == "call_next1", "the next call's id, chosen now: the grant names it")
        #expect(ask.json?["publishableKey"] as? String == DirectFixture.key)
        #expect((ask.json?["identity"] as? [String: Any])?["value"] as? String == "customer-1")
        #expect(ask.json?["installId"] as? String == "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
        #expect(ask.json?["memory"] as? Bool == true)
        #expect(ask.json?["timezone"] as? String == "Asia/Kolkata")
        #expect(ask.json?["session_id"] == nil && ask.json?["variables"] == nil)
        #expect(ask.timeout == 10)
        #expect(d.gateway.kinds() == [.grantOnly, .probe], "and the gateway asked once")
        #expect(d.next?.callId == "call_next1" && d.next?.grant == DirectFixture.grant(1))
    }

    @Test func aNextCallsIdIsShapedAsTheCoreNamesCalls() {
        let id = RtcDirectMint.freshCallId()
        #expect(id.hasPrefix("call_") && id == id.lowercased())
        #expect(UUID(uuidString: String(id.dropFirst(5))) != nil)
    }

    @Test func startCallTakesTheWarmIdAndMintsAtTheGateway() throws {
        let d = DirectRig()
        d.warm()
        let rig = d.place()
        #expect(d.lastId == "call_next1", "the call takes the id its grant was asked for")
        rig.ready()
        #expect(rig.minting.requests.isEmpty, "the web route was never asked")
        let direct = try #require(d.gateway.directs.first)
        #expect(direct.url == DirectFixture.route)
        #expect(direct.grant == DirectFixture.grant(1))
        #expect(direct.json?["session_id"] as? String == rig.engine.sessionId, "the control channel's session")
        #expect((direct.json?["variables"] as? [String: Any])?["call_reason"] as? String == "card_blocked")
        #expect(direct.json?["identity"] == nil && direct.json?["publishableKey"] == nil && direct.json?["callId"] == nil,
                "who the customer is, and which call, ride in the grant")
        #expect(direct.timeout == 4)
        #expect(rig.names == ["ready"])
        #expect(rig.lines.contains { $0.hasPrefix("rtc: minted at the gateway in") })
    }

    @Test func aNextCallsIdIsTakenOnce() {
        let d = DirectRig()
        d.warm()
        #expect(d.take() == "call_next1")
        #expect(d.take() == nil, "the grant is that call's now: the next one follows its mint")
        #expect(d.take(customer: "customer-2") == nil, "never another customer's")
    }

    @Test func aCallWithAnyOtherIdTakesTheWebRoute() {
        let d = DirectRig()
        d.warm()
        let rig = d.call(callId: "call_placedelsewhere")
        rig.ready()
        #expect(d.gateway.directs.isEmpty, "a grant asked for call_next1 never carries another call")
        #expect(rig.minting.requests.count == 1)
        #expect(rig.names == ["ready"])
        #expect(rig.lines.contains("rtc: direct mint: no grant for this call — minting on the web route"))
        #expect(d.next?.callId == "call_next1", "still the next call's")
        #expect(d.gateway.kinds() == [.grantOnly, .probe], "and nothing asked for: the next call's grant is usable")
    }

    @Test func afterACallAGrantForAFreshNextIdIsFetched() throws {
        let d = DirectRig()
        d.warm()
        let first = d.place()
        first.ready()
        #expect(d.gateway.kinds() == [.grantOnly, .probe, .direct, .grantOnly], "the call's mint, then the next call's grant")
        #expect(d.gateway.sent.last?.json?["callId"] as? String == "call_next2", "for a fresh id")
        #expect(d.next?.callId == "call_next2" && d.next?.grant == DirectFixture.grant(2))
        first.engine.hangUp()

        let second = d.place()
        second.ready()
        #expect(d.lastId == "call_next2")
        #expect(second.minting.requests.isEmpty)
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(2))
    }

    @Test func withoutAGrantTheCallMintsOnTheWebRouteAndTheNextCallsGrantFollows() {
        let d = DirectRig()
        let first = d.place()
        #expect(d.lastId == "call_own1", "no grant in hand: an id of its own")
        first.ready()
        #expect(first.minting.requests.count == 1)
        #expect(first.names == ["ready"])
        #expect(first.lines.contains("rtc: direct mint: no grant for this call — minting on the web route"))
        #expect(d.gateway.kinds() == [.grantOnly, .probe], "the next call's grant, fetched behind this one")
        #expect(d.next?.callId == "call_next1")
        first.engine.hangUp()

        let second = d.place()
        second.ready()
        #expect(second.minting.requests.isEmpty)
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(1))
    }

    /// The grant beside a web-route credential is that call's own: its redial's mint goes to the gateway.
    @Test func aWebRouteGrantServesThatCallsOwnRedial() {
        let d = DirectRig()
        let rig = d.call(callId: "call_redial000001")
        var answer = MintFixture.credential
        answer.expiresAt = Date(timeIntervalSinceNow: 5)      // too little life for a fresh connection: minted again
        answer.direct = DirectFixture.offer(7)
        rig.minting.outcome = .credential(answer)
        rig.sbc.sendTrying = false
        rig.sbc.challenge = false
        rig.sbc.inviteFinal = nil
        rig.ready()
        rig.engine.audioActivated()
        #expect(rig.minting.requests.count == 1)
        #expect(d.grant(for: "call_redial000001") == DirectFixture.grant(7), "kept for exactly that call")
        #expect(d.next?.callId == "call_next1", "the next call's grant is its own")
        d.clock.advance(4.1)                                  // no reply to the INVITE: a fresh connection, a new credential
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(7), "the redial minted at the gateway")
        #expect(rig.minting.requests.count == 1, "not the web route again")
    }

    // MARK: A call that rings

    @Test func aRingingCallsGrantIsAskedForItsOwnIdAndTheAnsweredCallMintsAtTheGateway() throws {
        let d = DirectRig()
        d.ring("call_ring000001")
        let ask = try #require(d.gateway.sent.first)
        #expect(ask.kind == .grantOnly)
        #expect(ask.json?["callId"] as? String == "call_ring000001", "the ring's own id: the grant names that call")
        #expect((ask.json?["identity"] as? [String: Any])?["value"] as? String == "customer-1")
        #expect(d.grant(for: "call_ring000001") == DirectFixture.grant(1))
        #expect(d.next == nil, "not the next call's")
        let answered = d.call(callId: "call_ring000001")
        answered.ready()
        #expect(answered.minting.requests.isEmpty, "answered, it mints at the gateway")
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(1))
    }

    @Test func aRingWhoseGrantIsNotReadyMintsOnTheWebRoute() {
        let d = DirectRig()
        d.gateway.holding = [.grantOnly]
        d.ring("call_ring000002")
        let answered = d.call(callId: "call_ring000002")
        answered.ready()
        #expect(answered.minting.requests.count == 1, "not ready when it is minted: the web route, as before")
        #expect(d.gateway.directs.isEmpty)
        #expect(answered.names == ["ready"])
    }

    @Test func aRingAskedForAgainSendsNothingMore() {
        let d = DirectRig()
        d.gateway.holding = [.grantOnly]
        d.ring("call_ring000003")
        d.ring("call_ring000003")
        #expect(d.gateway.kinds() == [.grantOnly], "on its way: not asked twice")
        d.gateway.release(.grantOnly)
        d.ring("call_ring000003")
        #expect(d.gateway.kinds() == [.grantOnly, .probe], "in hand: not asked again")
    }

    // MARK: Warm-ups cost nothing while a grant is usable

    /// configure, identify, setMemory and every return to the foreground warm up: with a usable grant, they cost nothing.
    @Test func aSecondWarmUpInTheGrantsFirstHalfSendsNoRequest() {
        let d = DirectRig()
        d.warm()
        #expect(d.gateway.kinds() == [.grantOnly, .probe])
        for seconds in [1.0, 60, 300, 448] {
            d.clock.advance(seconds - (d.clock.now - 1_000))
            d.warm()
        }
        #expect(d.gateway.sent.count == 2, "no request at all, to the web route or the gateway, while it is not half spent")
        d.clock.advance(2)
        d.warm()
        #expect(d.gateway.kinds() == [.grantOnly, .probe, .grantOnly], "half spent: renewed, and the gateway not asked again")
        #expect(d.gateway.sent[2].json?["callId"] as? String == "call_next1", "for the same next call")
        #expect(d.next?.grant == DirectFixture.grant(2))
        d.warm()
        #expect(d.gateway.sent.count == 3, "and the new one costs nothing either")
    }

    /// A grant short enough that its last 30 s come before its half-life is asked for again in them.
    @Test func aWarmUpAsksForANewGrantWhenTheOneInHandLapsesWithin30Seconds() {
        let d = DirectRig()
        d.gateway.grantOnly = { n in
            .answered(status: 200, data: try! JSONSerialization.data(withJSONObject: ["direct": DirectFixture.offerJSON(n, ttlMs: 50_000)]))
        }
        d.warm()
        d.clock.advance(19)
        d.warm()
        #expect(d.gateway.kinds() == [.grantOnly, .probe], "31 s left: usable")
        d.clock.advance(2)
        d.warm()
        #expect(d.gateway.kinds() == [.grantOnly, .probe, .grantOnly], "29 s left, though not half spent: the next one")
    }

    @Test func pastHalfItsLifeTheNextCallsGrantIsRenewedForTheSameCall() {
        let d = DirectRig()
        d.warm()
        d.clock.advance(451)
        d.warm()
        #expect(d.gateway.sent.last?.json?["callId"] as? String == "call_next1")
        #expect(d.next?.grant == DirectFixture.grant(2))
        let rig = d.place()
        rig.ready()
        #expect(d.lastId == "call_next1")
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(2), "the renewed grant, for the same call")

        // A half-spent grant still carries the call that takes it; the next call's follows that call's mint.
        let half = DirectRig()
        half.warm()
        half.clock.advance(451)
        let call = half.place()
        call.ready()
        #expect(half.gateway.directs.last?.grant == DirectFixture.grant(1))
        #expect(half.next?.callId == "call_next2" && half.next?.grant == DirectFixture.grant(2))
    }

    // MARK: Falling back

    @Test func aRefusedGrantIsLetGoAndTheCallMintsOnTheWebRoute() {
        for status in [401, 403] {
            let d = DirectRig()
            d.warm()
            d.gateway.direct = [DirectFixture.refusal(status, "grant_invalid", "This call grant is not valid or has expired.")]
            let rig = d.place()
            rig.ready()
            #expect(d.gateway.directs.count == 1)
            #expect(rig.minting.requests.count == 1, "\(status): the web route, at once")
            #expect(rig.names == ["ready"])
            #expect(d.grant(for: "call_next1") == nil, "the refused grant is let go")
            #expect(rig.lines.contains("rtc: direct mint: the gateway refused the grant (\(status) grant_invalid) — minting on the web route"))
            #expect(d.mint.restReason == nil, "one refusal is not the secret disagreeing")
        }
    }

    @Test func aSpentGrantIsLetGoAndTheCallMintsOnTheWebRoute() {
        let d = DirectRig()
        d.warm()
        d.gateway.direct = [DirectFixture.refusal(429, "grant_budget")]
        let rig = d.place()
        rig.ready()
        #expect(rig.minting.requests.count == 1)
        #expect(rig.names == ["ready"])
        #expect(d.grant(for: "call_next1") == nil)
        rig.engine.hangUp()
        let next = d.place()
        next.ready()
        #expect(next.minting.requests.isEmpty, "the next call's own grant, fetched behind the first")
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(2))
    }

    @Test func aGatewayThatDoesNotAnswerCostsOneRequestThenTheWebRoute() {
        let d = DirectRig()
        d.warm()
        d.gateway.direct = [.failed("The Internet connection appears to be offline.")]
        let rig = d.place()
        rig.ready()
        #expect(rig.minting.requests.count == 1)
        #expect(rig.names == ["ready"])
        #expect(d.grant(for: "call_next1") == DirectFixture.grant(1), "the grant was not at fault")
        #expect(d.mint.restReason == nil, "one is not two")
    }

    @Test func aDirectMintWithoutAnAnswerIn4SecondsIsAbandoned() {
        let d = DirectRig()
        d.warm()
        d.gateway.holding = [.direct]
        let rig = d.place()
        rig.ready()
        #expect(rig.minting.requests.isEmpty)
        d.clock.advance(3.9)
        #expect(rig.minting.requests.isEmpty, "still the gateway's turn")
        d.clock.advance(0.2)
        #expect(rig.minting.requests.count == 1, "the web route")
        rig.openSip()
        #expect(rig.names == ["ready"])
        d.gateway.release(.direct)
        #expect(rig.names == ["ready"], "a late answer changes nothing")
        #expect(rig.lines.contains { $0.contains("the gateway did not answer (timed out after 4 s)") })
    }

    // MARK: Resting

    /// Off is ten minutes, not the process: a phone keeps an app's process for days.
    @Test func afterTwoUnansweredMintsNothingDirectForTenMinutesThenAProbe() {
        let d = DirectRig()
        d.warm()
        d.gateway.direct = [.failed("offline"), .failed("offline")]
        for n in 1...2 {
            let rig = d.place()
            rig.ready()
            #expect(rig.minting.requests.count == 1, "call \(n): the web route")
            rig.engine.hangUp()
        }
        #expect(d.mint.restReason == "2 direct requests in a row never answered")
        let asked = d.gateway.sent.count

        // Resting: calls on the web route, and nobody asked anything — not even for the next call's grant.
        d.clock.advance(500)
        let resting = d.place()
        resting.ready()
        #expect(resting.minting.requests.count == 1)
        #expect(resting.lines.contains("rtc: direct mint: resting (2 direct requests in a row never answered) — minting on the web route"))
        resting.engine.hangUp()
        d.warm()
        d.clock.advance(99)
        #expect(d.gateway.sent.count == asked, "no direct mint, no probe, no grant for 599 s")

        // Ten minutes: the gateway asked again; the next warm-up brings a grant, and the direct mint is back.
        d.clock.advance(2)
        #expect(d.gateway.kinds().suffix(1) == [.probe])
        #expect(d.gateway.sent.count == asked + 1)
        #expect(d.mint.restReason == nil)
        d.warm()
        let back = d.place()
        back.ready()
        #expect(back.minting.requests.isEmpty)
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(3))
    }

    @Test func twoGrantsRefusedInARowRestTheDirectMintForTenMinutes() {
        let d = DirectRig()
        for n in 1...2 {
            d.warm()
            d.gateway.direct = [DirectFixture.refusal(401, "grant_invalid")]
            let rig = d.place()
            rig.ready()
            #expect(rig.minting.requests.count == 1, "grant \(n) refused: the web route")
            rig.engine.hangUp()
        }
        #expect(d.mint.restReason == "the gateway refused 2 grants in a row")
        let asked = d.gateway.sent.count
        d.warm()
        let rig = d.place()
        rig.ready()
        #expect(d.gateway.sent.count == asked, "resting: no grant asked for, nothing taken to the gateway")
        #expect(rig.minting.requests.count == 1)
        rig.engine.hangUp()

        d.clock.advance(601)
        #expect(d.gateway.kinds().suffix(1) == [.probe], "asked again")
        d.warm()
        #expect(d.gateway.kinds().suffix(1) == [.grantOnly], "and a grant asked for again, the refused ones being gone")
        let after = d.place()
        after.ready()
        #expect(after.minting.requests.isEmpty)
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(3))
    }

    /// A rest is counted on the wall clock: a phone that slept through it is not left resting.
    @Test func aRestThePhoneSleptThroughIsOverWhenItWakes() {
        let d = DirectRig()
        d.warm()
        d.gateway.direct = [.failed("offline"), .failed("offline")]
        for _ in 1...2 {
            let rig = d.place()
            rig.ready()
            rig.engine.hangUp()
        }
        #expect(d.mint.restReason != nil)
        d.skew += 700                                   // asleep: the wall moved, the scheduling clock did not
        d.warm()                                        // the app comes back
        #expect(d.mint.restReason == nil)
        #expect(d.gateway.kinds().suffix(2) == [.probe, .grantOnly], "asked again at once, and the next call's grant")
        let rig = d.place()
        rig.ready()
        #expect(rig.minting.requests.isEmpty)
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(3))
    }

    @Test func aGatewayThatSaysAnythingButYesRestsTheDirectMintTenMinutes() {
        let answers: [(RtcHTTPAnswer, Int)] = [
            (.answered(status: 404, data: Data(#"{"detail":"Not Found"}"#.utf8)), 404),
            (.answered(status: 200, data: Data(#"{"direct":false}"#.utf8)), 200),
            (.answered(status: 200, data: Data(#"{"direct":1}"#.utf8)), 200),
            (.answered(status: 503, data: nil), 503),
        ]
        for (probe, status) in answers {
            let d = DirectRig()
            d.gateway.probe = probe
            d.warm()
            #expect(d.mint.restReason == "the gateway takes no grants (\(status))")
            let rig = d.place()
            rig.ready()
            #expect(d.gateway.directs.isEmpty, "\(probe)")
            #expect(rig.minting.requests.count == 1)
            #expect(rig.names == ["ready"])
            d.warm()
            d.clock.advance(599)
            #expect(d.gateway.kinds().filter { $0 == .probe }.count == 1, "not asked again while resting")
            d.clock.advance(2)
            #expect(d.gateway.kinds().filter { $0 == .probe }.count == 2, "asked again after ten minutes")
        }
    }

    /// The grant in hand is kept through a rest: still good after it, the next call takes it.
    @Test func aGatewayThatSaysYesAfterTheRestTakesTheGrantKeptThroughIt() {
        let d = DirectRig()
        d.gateway.probe = .answered(status: 404, data: nil)
        d.warm()
        #expect(d.mint.restReason != nil)
        #expect(d.take() == nil, "resting: the next call's id stays with its grant")
        d.gateway.probe = .answered(status: 200, data: Data(#"{"direct":true}"#.utf8))
        d.clock.advance(601)
        #expect(d.mint.probeState(DirectFixture.route) == .ready)
        let rig = d.place()
        rig.ready()
        #expect(d.lastId == "call_next1")
        #expect(rig.minting.requests.isEmpty)
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(1))
    }

    // MARK: A gate's refusal

    /// The same refusal, in the same words, the web route's mint would have given: the call ends, no second road.
    @Test func aGatesRefusalEndsTheCallAsTheWebRoutesWould() throws {
        for code in ["insufficient_credits", "parent_out_of_credits", "monthly_cap", "agent_off", "agent_deleted"] {
            let d = DirectRig()
            d.warm()
            let status = code.hasPrefix("agent") ? 409 : 402
            d.gateway.direct = [DirectFixture.refusal(status, code, "No, because \(code).")]
            let rig = d.place()
            rig.ready()
            #expect(rig.names == ["refused(\(code))"])
            #expect(rig.minting.requests.isEmpty, "\(code): not asked again on the web route")
            guard case let .refused(_, message)? = rig.events.first(where: { if case .refused = $0 { return true }; return false }) else {
                Issue.record("no refusal for \(code)")
                continue
            }
            #expect(message == "No, because \(code).")
            #expect(d.grant(for: "call_next1") == DirectFixture.grant(1), "the grant was fine: the call was not")
        }
    }

    /// The gateway's credit refusal carries no code (the web route passes it on the same way): the call is the socket's.
    @Test func aCreditRefusalWithoutACodeFallsBackAsTheWebRoutesDoes() {
        let d = DirectRig()
        d.warm()
        d.gateway.direct = [DirectFixture.refusal(402, nil, "Insufficient credits.")]
        let rig = d.place()
        rig.ready()
        #expect(rig.names == ["unreachable(mint_failed)"])
        #expect(rig.minting.requests.isEmpty, "the web route would only refuse it again")
    }

    @Test func anyOtherAnswerMintsOnTheWebRoute() {
        for (answer, kept) in [
            (DirectFixture.refusal(404, nil, "Agent not found"), false),
            (DirectFixture.refusal(503, nil, "Billing unavailable"), true),
            (RtcHTTPAnswer.answered(status: 200, data: Data("{}".utf8)), true),
        ] {
            let d = DirectRig()
            d.warm()
            d.gateway.direct = [answer]
            let rig = d.place()
            rig.ready()
            #expect(rig.minting.requests.count == 1)
            #expect(rig.names == ["ready"])
            #expect((d.grant(for: "call_next1") != nil) == kept, "\(answer)")
        }
    }

    // MARK: A grant's life

    @Test func aGrantWithLessThan30SecondsLeftIsNotUsed() {
        let first: (Int) -> RtcHTTPAnswer = { n in n == 1 ? .answered(status: 200, data: DirectFixture.grantOnlyAnswer(1)) : .failed("offline") }
        let d = DirectRig()
        d.gateway.grantOnly = first
        d.warm()
        d.clock.advance(869)
        #expect(d.take() == "call_next1", "31 s left: taken")

        let late = DirectRig()
        late.gateway.grantOnly = first
        late.warm()
        late.clock.advance(871)
        #expect(late.take() == nil, "29 s left: the call takes an id of its own")
        let named = late.call(callId: "call_next1")
        named.ready()
        #expect(named.minting.requests.count == 1)
        #expect(named.lines.contains("rtc: direct mint: the grant in hand has lapsed — minting on the web route"))
    }

    /// Timed from arrival by this device: the life the web route states, else its expiry read once, on arrival.
    @Test func aGrantsLifeIsTimedFromItsArrival() {
        // An hour ahead of the server: the stated life still holds.
        let ahead = DirectRig()
        ahead.skew = 3600
        ahead.warm()
        ahead.clock.advance(800)
        let rig = ahead.place()
        rig.ready()
        #expect(rig.minting.requests.isEmpty)

        // No stated life: ten minutes left by its expiry, counted from now on this device's own clock (and no renewal).
        let unstated = DirectRig()
        unstated.gateway.grantOnly = { n in
            n > 1 ? .failed("offline") : .answered(status: 200, data: try! JSONSerialization.data(withJSONObject: [
                "direct": DirectFixture.offerJSON(n, ttlMs: nil, expiresAtMs: (DirectFixture.wall + 600) * 1000),
            ]))
        }
        unstated.warm()
        unstated.clock.advance(569)
        let inTime = unstated.place()
        inTime.ready()
        #expect(inTime.minting.requests.isEmpty)
        inTime.engine.hangUp()
        unstated.clock.advance(2)
        let late = unstated.place()
        late.ready()
        #expect(late.minting.requests.count == 1)
    }

    /// A grant's life runs on the wall clock too: one a phone slept through hands its id to no call.
    @Test func aGrantThePhoneSleptThroughIsSeenLapsed() {
        let d = DirectRig()
        d.gateway.grantOnly = { n in n == 1 ? .answered(status: 200, data: DirectFixture.grantOnlyAnswer(1)) : .failed("offline") }
        d.warm()
        d.skew += 1_000
        let rig = d.place()
        #expect(d.lastId == "call_own1")
        rig.ready()
        #expect(d.gateway.directs.isEmpty)
        #expect(rig.minting.requests.count == 1)
    }

    // MARK: Who it is for

    @Test func aGrantForAnotherCustomerIsLetGo() {
        let d = DirectRig()
        d.warm(customer: "customer-1")
        let rig = d.place(customer: "customer-2")
        #expect(d.lastId == "call_own1", "the last customer's next id is not this customer's")
        rig.ready()
        #expect(d.gateway.directs.isEmpty, "the last customer's grant never reaches the gateway")
        #expect(rig.minting.requests.count == 1)
        #expect(d.grant(for: "call_next1") == nil, "and is let go")

        let memory = DirectRig()
        memory.warm(memory: true)
        let off = memory.place(memory: false)
        off.ready()
        #expect(memory.gateway.directs.isEmpty, "their memory choice is in the grant too")
    }

    @Test func anotherCustomerWarmsAGrantOfTheirOwn() {
        let d = DirectRig()
        d.warm(customer: "customer-1")
        d.warm(customer: "customer-2")
        #expect(d.gateway.kinds() == [.grantOnly, .probe, .grantOnly])
        #expect((d.gateway.sent[2].json?["identity"] as? [String: Any])?["value"] as? String == "customer-2")
        #expect(d.gateway.sent[2].json?["callId"] as? String == "call_next2", "a next call of their own")
        #expect(d.next?.grant == DirectFixture.grant(2))
        let rig = d.place(customer: "customer-2")
        rig.ready()
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(2))

        let signedOut = DirectRig()
        signedOut.warm(customer: "customer-1")
        signedOut.warm(customer: nil)
        #expect(signedOut.gateway.sent.last?.json?["identity"] == nil, "signed out: a grant for nobody in particular")
        #expect(signedOut.next?.grant == DirectFixture.grant(2))
    }

    @Test func aCustomerWhoChangesWhileAGrantIsAskedForGetsTheirOwn() {
        let d = DirectRig()
        d.gateway.holding = [.grantOnly]
        d.warm(customer: "customer-1")
        d.warm(customer: "customer-2")
        #expect(d.gateway.kinds() == [.grantOnly, .grantOnly], "the first is nobody's now: the new customer's is asked for at once")
        d.gateway.release(.grantOnly)
        #expect(d.next?.callId == "call_next2" && d.next?.grant == DirectFixture.grant(2))
        #expect(d.grant(for: "call_next1") == nil, "the first customer's answer is kept for nobody")
        let rig = d.place(customer: "customer-2")
        rig.ready()
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(2))
    }

    // MARK: Is the gateway there

    @Test func aProbeOnItsWayIsWaitedFor() {
        let d = DirectRig()
        d.gateway.holding = [.probe]
        d.warm()
        let rig = d.place()
        rig.engine.prepare()
        #expect(rig.minting.requests.isEmpty && d.gateway.directs.isEmpty, "waiting for the gateway's answer")
        d.gateway.release(.probe)
        #expect(d.gateway.directs.count == 1, "it said yes: the mint rides its connection")
        rig.openSip()
        rig.engine.begin()
        #expect(rig.minting.requests.isEmpty)
        #expect(rig.names == ["ready"])
    }

    @Test func aProbeThatNeverAnsweredIsAskedAgainWithoutHoldingACall() {
        let d = DirectRig()
        d.gateway.probe = .failed("offline")
        d.warm()
        #expect(d.mint.probeState(DirectFixture.route) == nil, "no answer is not a no")
        d.gateway.probe = .answered(status: 200, data: Data(#"{"direct":true}"#.utf8))
        let rig = d.place()
        rig.ready()
        #expect(rig.minting.requests.count == 1, "this call does not wait for the gateway")
        #expect(d.mint.probeState(DirectFixture.route) == .ready, "asked again behind it")
        rig.engine.hangUp()
        let next = d.place()
        next.ready()
        #expect(next.minting.requests.isEmpty)
        #expect(d.gateway.directs.count == 1)
    }

    @Test func aWebRouteThatSignsNoGrantsIsNotAskedAgain() {
        let d = DirectRig()
        d.gateway.grantOnly = { _ in .answered(status: 200, data: Data(#"{"direct":null}"#.utf8)) }
        d.warm()
        d.warm()
        d.clock.advance(3600)
        d.warm(customer: "customer-2")
        #expect(d.gateway.kinds() == [.grantOnly], "the deployment has no direct path: nothing more to ask")
        // Until a mint brings a grant after all — that call's own.
        let rig = d.place(customer: "customer-2")
        var answer = MintFixture.credential
        answer.direct = DirectFixture.offer(9)
        rig.minting.outcome = .credential(answer)
        rig.ready()
        #expect(d.grant(for: d.lastId) == DirectFixture.grant(9))
    }

    // MARK: Before the customer was known

    /// A call (and its ring) asked for before the customer was known — a push-woken app — forgets nobody's grants: only the app's own warm-ups do.
    @Test func aCallPreparedBeforeTheCustomerWasKnownLeavesTheirGrantsAlone() {
        let d = DirectRig()
        d.warm(customer: "customer-1")                          // the app: the next call's grant (call_next1), grant 1
        d.ring("call_ring000020", customer: "customer-1")       // the ring's own, under the customer: grant 2
        // The leg prepared before the session said who the customer is: its ring's grant and its mint, for nobody.
        d.ring("call_ring000020", customer: nil)                // grant 3
        let early = d.call(callId: "call_ring000020", customer: nil)
        early.ready()
        #expect(d.next?.callId == "call_next1" && d.next?.grant == DirectFixture.grant(1), "the customer's next call's grant stands")
        #expect(d.grant(for: "call_ring000020", customer: "customer-1") == DirectFixture.grant(2), "and the ring's own, under them")
        #expect(d.gateway.kinds().filter { $0 == .grantOnly }.count == 3, "and nothing asked for nobody's next call behind the early mint")
        let answered = d.call(callId: "call_ring000020", customer: "customer-1")
        answered.ready()
        #expect(answered.minting.requests.isEmpty)
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(2))
    }

    /// The session arrives (or identify) while it rings: the app's warm-up, and the ring's grant asked for again under who it is now.
    @Test func whenTheCustomerBecomesKnownMidRingTheRingsGrantIsAskedForUnderThem() {
        let d = DirectRig()
        d.ring("call_ring000021", customer: nil)                // woken by the push: nobody known yet
        #expect(d.grant(for: "call_ring000021", customer: nil) == DirectFixture.grant(1))
        d.warm(customer: "customer-1")
        d.ring("call_ring000021", customer: "customer-1")
        #expect(d.grant(for: "call_ring000021", customer: nil) == nil, "the app's warm-up let nobody's go")
        #expect(d.grant(for: "call_ring000021", customer: "customer-1") == DirectFixture.grant(3))
        let answered = d.call(callId: "call_ring000021", customer: "customer-1")
        answered.ready()
        #expect(answered.minting.requests.isEmpty, "the leg minted again at the answer goes to the gateway")
        #expect(d.gateway.directs.last?.grant == DirectFixture.grant(3))
    }

    // MARK: A refused grant request

    @Test func aRefusedGrantRequestHoldsTheNextBackAMinute() {
        let d = DirectRig()
        d.gateway.grantOnly = { n in
            n == 1 ? .answered(status: 403, data: Data(#"{"error":"Add app:// to Allowed domains.","code":"no_origin"}"#.utf8))
                : .answered(status: 200, data: DirectFixture.grantOnlyAnswer(n))
        }
        let asks = { d.gateway.kinds().filter { $0 == .grantOnly }.count }
        d.warm()
        d.warm()
        d.ring("call_ring000022")
        let rig = d.place()
        rig.ready()
        rig.engine.hangUp()
        d.clock.advance(59)
        d.warm()
        #expect(asks() == 1, "refused: no grant asked for — the app's, a ring's, or behind a call — for a minute")
        #expect(d.mint.restReason == nil, "a refused request is a pause, not a rest")
        d.clock.advance(2)
        d.warm()
        #expect(asks() == 2, "then asked again")
        #expect(d.next?.grant == DirectFixture.grant(2))
    }

    @Test func aRateLimitedGrantRequestWaitsTheRetryAfterItNamed() {
        let d = DirectRig()
        d.gateway.grantOnly = { n in
            n == 1 ? .answered(status: 429, data: Data(#"{"error":"Too many requests.","code":"rate_limited"}"#.utf8), retryAfter: 120)
                : .answered(status: 200, data: DirectFixture.grantOnlyAnswer(n))
        }
        let asks = { d.gateway.kinds().filter { $0 == .grantOnly }.count }
        d.warm()
        d.clock.advance(61)
        d.warm()
        #expect(asks() == 1, "the Retry-After it named, not a minute")
        d.clock.advance(60)
        d.warm()
        #expect(asks() == 2)
        #expect(d.next?.grant == DirectFixture.grant(2))
    }

    /// A pause holds back grant requests only: the grant in hand still mints at the gateway.
    @Test func aPausedAgentStillMintsWithTheGrantInHand() {
        let d = DirectRig()
        d.gateway.grantOnly = { n in
            n == 1 ? .answered(status: 200, data: DirectFixture.grantOnlyAnswer(1)) : .answered(status: 503, data: nil)
        }
        d.warm()
        d.clock.advance(451)
        d.warm()                                                // the renewal, refused
        let rig = d.place()
        rig.ready()
        #expect(d.lastId == "call_next1")
        #expect(rig.minting.requests.isEmpty)
        #expect(d.gateway.kinds().filter { $0 == .grantOnly }.count == 2, "and nothing asked for behind it, during the pause")
    }

    @Test func retryAfterIsReadInSeconds() {
        func response(_ value: String?) -> HTTPURLResponse? {
            HTTPURLResponse(url: DirectFixture.route, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: value.map { ["Retry-After": $0] } ?? [:])
        }
        #expect(URLSessionRtcHTTP.retryAfter(response("120")) == 120)
        #expect(URLSessionRtcHTTP.retryAfter(response("7")) == 7)
        #expect(URLSessionRtcHTTP.retryAfter(response("Wed, 21 Oct 2026 07:28:00 GMT")) == nil, "the date form: a minute instead")
        #expect(URLSessionRtcHTTP.retryAfter(response("-3")) == nil)
        #expect(URLSessionRtcHTTP.retryAfter(response(nil)) == nil)
        #expect(URLSessionRtcHTTP.retryAfter(nil) == nil)
    }

    // MARK: The pieces

    @Test func anOfferIsTheVoiceBarsShapeOrNothing() throws {
        let good = try #require(RtcDirectOffer.parse(DirectFixture.offerJSON(1)))
        #expect(good.grant == "v1.grant-1.sig" && good.ttlMs == 900_000 && good.url == DirectFixture.route)
        #expect(RtcDirectOffer.parse(DirectFixture.offerJSON(1, ttlMs: nil))?.ttlMs == nil, "the life is optional")
        var bad: [[String: Any]] = []
        let changes: [(String, Any)] = [
            ("grant", "v2.x.y"), ("grant", 7), ("url", "http://gw.example.test/x"), ("url", "wss://gw.example.test/x"),
            ("expires_at", "1792000900000"), ("expires_at", true), ("ttl_ms", 0), ("ttl_ms", -5), ("ttl_ms", "900000"), ("ttl_ms", NSNull()),
        ]
        for (key, value) in changes {
            var o = DirectFixture.offerJSON(1)
            o[key] = value
            bad.append(o)
        }
        for o in bad { #expect(RtcDirectOffer.parse(o) == nil, "\(o)") }
        #expect(RtcDirectOffer.parse(nil) == nil && RtcDirectOffer.parse(NSNull()) == nil)
    }

    @Test func theWebRoutesAnswerCarriesItsGrant() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(MintFixture.response.utf8)) as? [String: Any])
        #expect(RtcCredential.parse(Data(MintFixture.response.utf8))?.direct == nil, "an offer that is not one is ignored")
        object["direct"] = DirectFixture.offerJSON(3)
        let credential = try #require(RtcCredential.parse(try JSONSerialization.data(withJSONObject: object)))
        #expect(credential.direct == DirectFixture.offer(3))
        #expect(credential.username == "web-0123456789abcdef", "the credential itself unchanged")
    }

    @Test func theMintsBodyReadsBackIntoWhoAndTheCall() throws {
        let parts = try #require(RtcMintBodyParts(DirectFixture.body(sessionId: "s-1", callId: "call_1234567890")))
        #expect(parts.publishableKey == DirectFixture.key)
        #expect(parts.sessionId == "s-1" && parts.callId == "call_1234567890")
        #expect(Set(parts.identityFields.keys) == ["publishableKey", "identity", "installId", "memory", "timezone"])
        let other = try #require(RtcMintBodyParts(DirectFixture.body(sessionId: "s-2", callId: "call_0987654321")))
        #expect(parts.identityKey == other.identityKey, "another call, the same customer")
        #expect(parts.identityKey != RtcMintBodyParts(DirectFixture.body(customer: "customer-2"))?.identityKey)
        let grantOnly = try #require(try JSONSerialization.jsonObject(with: parts.grantOnlyBody(callId: "call_next9")) as? [String: Any])
        #expect(grantOnly["callId"] as? String == "call_next9" && grantOnly["grant_only"] as? Bool == true)
        #expect(grantOnly["session_id"] == nil && grantOnly["variables"] == nil)
        let direct = try #require(try JSONSerialization.jsonObject(with: parts.directBody(grant: "v1.g.s")) as? [String: Any])
        #expect(Set(direct.keys) == ["grant", "session_id", "variables"])
        #expect(RtcMintBodyParts(Data(#"{"session_id":"s"}"#.utf8)) == nil, "no key, no grant")
        #expect(RtcMintBodyParts(Data("[]".utf8)) == nil)
    }
}
