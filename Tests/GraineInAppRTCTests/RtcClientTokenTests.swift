import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * SERVER TOKENS ON WEBRTC (CLIENT-TOKENS.md §2.2–2.3): the call's mint and a
 * grant request to the web route carry the agent's newest token as
 * `clientToken` (never inside the mint body the call was prepared with); a
 * refusal a fresh token can lift is minted once more with the new token; one
 * for the token's scope or a revoked key ends the call — no fallback to the
 * WebSocket, which would meet the same answer.
 */
@Suite struct RtcClientTokenTests {
    /// A timer that never fires: the test's provider answers at once.
    private final class NeverTimer: CallTimer {
        func cancel() {}
    }

    /// A token manager whose provider answers `answer()` at once, each time it is asked.
    private func tokens(_ answer: @escaping () -> String?) -> (ClientTokens, () -> Int) {
        var asked = 0
        let manager = ClientTokens(fetch: { done in
            asked += 1
            done(answer())
        }, schedule: { _, _ in NeverTimer() }, background: { $0() })
        manager.start()
        return (manager, { asked })
    }

    /// Mints answered in order: each refusal or credential once, then credentials.
    private final class SequencedMinting: RtcMinting {
        var outcomes: [RtcMintOutcome]
        private(set) var bodies: [[String: Any]] = []
        init(_ outcomes: [RtcMintOutcome]) { self.outcomes = outcomes }
        func mint(_ url: URL, body: Data, done: @escaping (RtcMintOutcome) -> Void) {
            bodies.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
            done(outcomes.isEmpty ? .credential(MintFixture.credential) : outcomes.removeFirst())
        }
    }

    private func engine(_ minting: RtcMinting, tokens: ClientTokens?) -> (RtcCallEngine, () -> [GraineRtcEvent]) {
        let parts = RtcCallEngine.Parts(
            clock: ManualRtcClock(), sockets: MemorySocketFactory(), minting: minting, random: CountingRandom(),
            makeMedia: { _ in ScriptedMedia() }, audio: RecordingAudioControl(), direct: nil
        )
        let request = GraineRtcRequest(
            baseUrl: "https://www.graine.ai", controlHost: "wss://ws.graine.ai",
            mintBody: { id in Data(#"{"publishableKey":"pk_test_rig","session_id":"\#(id)"}"#.utf8) },
            sdkVersion: GraineRTCVersion.name, clientTokens: tokens.map { GraineRtcTokens($0) }
        )
        let call = RtcCallEngine(request: request, parts: parts)
        var events: [GraineRtcEvent] = []
        call.onEvent = { events.append($0) }
        return (call, { events })
    }

    private func refusals(_ events: [GraineRtcEvent]) -> [String] {
        events.compactMap { if case let .refused(code, _) = $0 { return code }; return nil }
    }

    private func fallbacks(_ events: [GraineRtcEvent]) -> Int {
        events.filter { if case .unreachable = $0 { return true }; return false }.count
    }

    @Test func theMintCarriesTheTokenAndTheBodyTheCallWasPreparedWithNever() {
        let (manager, _) = tokens { "tok_rtc" }
        let minting = SequencedMinting([])
        let (call, events) = engine(minting, tokens: manager)
        call.prepare()
        #expect(minting.bodies.first?[ClientTokenRules.field] as? String == "tok_rtc")
        #expect(minting.bodies.first?["publishableKey"] as? String == "pk_test_rig")
        #expect(refusals(events()).isEmpty && fallbacks(events()) == 0)
        call.hangUp()
        // Without tokens, the mint goes as it always did.
        let plain = SequencedMinting([])
        let (bare, _) = engine(plain, tokens: nil)
        bare.prepare()
        #expect(plain.bodies.first?[ClientTokenRules.field] == nil)
        bare.hangUp()
    }

    @Test func anExpiredTokenIsMintedOnceMoreWithTheFreshOne() {
        var next = "tok_old"
        let (manager, asked) = tokens { next }
        next = "tok_new"
        let minting = SequencedMinting([.refused(status: 401, code: "token_expired", message: "Expired.")])
        let (call, events) = engine(minting, tokens: manager)
        call.prepare()
        #expect(minting.bodies.map { $0[ClientTokenRules.field] as? String } == ["tok_old", "tok_new"], "exactly one retry, with the new token")
        #expect(asked() == 2, "exactly one more question")
        #expect(refusals(events()).isEmpty && fallbacks(events()) == 0, "the second mint brought the credential")
        call.hangUp()
    }

    @Test func theSameTokenBackLeavesTheRefusalStandingAndTheCallEnds() {
        let (manager, asked) = tokens { "tok_same" }
        let minting = SequencedMinting([.refused(status: 401, code: "token_invalid", message: nil)])
        let (call, events) = engine(minting, tokens: manager)
        call.prepare()
        #expect(minting.bodies.count == 1, "never retried with the same token")
        #expect(asked() == 2)
        #expect(refusals(events()) == ["token_invalid"], "final: the call ends with the code")
        #expect(fallbacks(events()) == 0, "and never moves to the WebSocket")
    }

    @Test func aRefusalForTheTokensScopeOrARevokedKeyEndsTheCallWithoutAFallback() {
        for code in ["token_scope", "key_revoked"] {
            let (manager, asked) = tokens { "tok_1" }
            let minting = SequencedMinting([.refused(status: code == "token_scope" ? 403 : 401, code: code, message: "No.")])
            let (call, events) = engine(minting, tokens: manager)
            call.prepare()
            #expect(minting.bodies.count == 1, "\(code): never retried")
            #expect(asked() == 1, "\(code): no token asked for")
            #expect(refusals(events()) == [code], "\(code): the call ends with it")
            #expect(fallbacks(events()) == 0, "\(code): no WebSocket past it")
        }
    }

    @Test func aGrantRequestCarriesTheToken() {
        let (manager, _) = tokens { "tok_grant" }
        let rig = DirectRig()
        rig.mint.warm(baseUrl: DirectFixture.base, body: DirectFixture.body(sessionId: ""), tokens: GraineRtcTokens(manager))
        let ask = rig.gateway.sent.first { $0.kind == .grantOnly }
        #expect(ask?.json?["grant_only"] as? Bool == true)
        #expect(ask?.json?[ClientTokenRules.field] as? String == "tok_grant")
        #expect(rig.next != nil, "and the grant was kept")
        // Without tokens: none sent.
        let plain = DirectRig()
        plain.warm()
        #expect(plain.gateway.sent.first { $0.kind == .grantOnly }?.json?[ClientTokenRules.field] == nil)
    }
}
