import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * YOUR APP AND YOUR USERS ON THE CALL SESSION (contract/APP-IDENTITY.md §1–§2):
 * the mint waits for what the core makes ready (a proof the agent requires, a
 * token about to expire) and reads its body only then; every answer goes back
 * to the core; `app_not_verified` is cured once and the mint made again; the
 * agent's refusal of the app ends the call without the WebSocket; and a
 * grant's renewal carries the app's declaration, keyed by who is calling —
 * the identity token included, never the passes that renew on their own.
 */
@Suite struct RtcAppIdentityTests {
    /// One call on fakes, with the core's hooks as the test writes them.
    final class Rig {
        let clock = ManualRtcClock()
        let sockets = MemorySocketFactory()
        let sbc = ScriptedSbc()
        let media = ScriptedMedia()
        let minting = ScriptedMinting()
        let audio = RecordingAudioControl()
        private(set) var events: [GraineRtcEvent] = []
        private(set) var bodiesRead = 0
        let engine: RtcCallEngine

        init(
            beforeMint: ((@escaping () -> Void) -> Void)? = nil,
            mintAnswered: ((Int, Data?) -> Void)? = nil,
            cure: ((String, @escaping (Bool) -> Void) -> Void)? = nil
        ) {
            let parts = RtcCallEngine.Parts(
                clock: clock, sockets: sockets, minting: minting, random: CountingRandom(),
                makeMedia: { [media] _ in media }, audio: audio, direct: nil
            )
            var read = 0
            var counter: () -> Void = {}
            let request = GraineRtcRequest(
                baseUrl: "https://www.graine.ai",
                controlHost: "wss://ws.graine.ai",
                mintBody: { id in
                    read += 1
                    counter()
                    return Data(#"{"publishableKey":"pk_test_rig","session_id":"\#(id)","app":{"platform":"ios","id":"com.acme.app","pass":"ap1.read-\#(read)"}}"#.utf8)
                },
                sdkVersion: "0.14.4",
                beforeMint: beforeMint,
                mintAnswered: mintAnswered,
                cure: cure
            )
            engine = RtcCallEngine(request: request, parts: parts)
            counter = { [unowned self] in self.bodiesRead += 1 }
            let sbc = self.sbc
            sockets.onOpen = { socket in if socket.protocols == ["sip"] { sbc.attach(socket) } }
            engine.onEvent = { [weak self] event in self?.events.append(event) }
        }

        var names: [String] {
            events.compactMap { event in
                switch event {
                case let .refused(code, _): return "refused(\(code))"
                case let .unreachable(reason, _): return "unreachable(\(reason.rawValue))"
                case .ready: return "ready"
                default: return nil
                }
            }
        }
    }

    @Test func theMintWaitsForWhatTheCoreMakesReadyAndReadsItsBodyAfter() throws {
        var go: (() -> Void)?
        let rig = Rig(beforeMint: { go = $0 })
        rig.engine.prepare()
        #expect(rig.minting.requests.isEmpty, "nothing minted while the core waits (a proof, a token)")
        #expect(rig.bodiesRead == 0, "the body is read after: it carries what the wait brought")
        let proceed = try #require(go)
        proceed()
        #expect(rig.minting.requests.count == 1)
        #expect(rig.bodiesRead == 1)
        let app = try #require(rig.minting.requests.first?.body["app"] as? [String: String])
        #expect(app["pass"] == "ap1.read-1")
    }

    @Test func everyAnswerOfTheCallSessionGoesBackToTheCore() throws {
        var heard: [(Int, [String: Any]?)] = []
        let answered: (Int, Data?) -> Void = { status, data in heard.append((status, data.flatMap { JSON.object(from: $0) })) }
        let rig = Rig(mintAnswered: answered)
        var credential = MintFixture.credential
        credential.verification = try JSONSerialization.data(withJSONObject: ["app": "verified", "user": "verified", "userPass": "up1.x", "userPassExpiresIn": 3600])
        rig.minting.outcome = .credential(credential)
        rig.engine.prepare()
        #expect(heard.count == 1)
        #expect(heard.first?.0 == 200)
        let verification = try #require(heard.first?.1?["verification"] as? [String: Any])
        #expect(verification["userPass"] as? String == "up1.x")

        var refusals: [(Int, [String: Any]?)] = []
        let refusedRig = Rig(mintAnswered: { status, data in refusals.append((status, data.flatMap { JSON.object(from: $0) })) })
        refusedRig.minting.outcome = .refused(status: 403, code: "app_not_allowed", message: "Not one of the agent's apps.")
        refusedRig.engine.prepare()
        #expect(refusals.first?.0 == 403)
        #expect(refusals.first?.1?["code"] as? String == "app_not_allowed")
    }

    @Test func appNotVerifiedIsCuredOnceAndTheMintMadeAgain() throws {
        var cured: [String] = []
        var rig: Rig!
        rig = Rig(cure: { code, retry in
            cured.append(code)
            rig.minting.outcome = .credential(MintFixture.credential)
            retry(true)
        })
        rig.minting.outcome = .refused(status: 403, code: "app_not_verified", message: "No pass.")
        rig.engine.prepare()
        #expect(cured == ["app_not_verified"])
        #expect(rig.minting.requests.count == 2, "minted once more")
        #expect(rig.bodiesRead == 2, "with a body read again — the new pass in it")
        #expect((rig.minting.requests.last?.body["app"] as? [String: String])?["pass"] == "ap1.read-2")
        #expect(!rig.names.contains { $0.hasPrefix("refused") || $0.hasPrefix("unreachable") })
    }

    @Test func aRefusalTheCoreCannotCureEndsTheCallWithoutTheWebSocket() {
        var cures = 0
        let rig = Rig(cure: { _, retry in
            cures += 1
            retry(false)
        })
        rig.minting.outcome = .refused(status: 403, code: "app_not_verified", message: "No pass.")
        rig.engine.prepare()
        #expect(cures == 1)
        #expect(rig.names == ["refused(app_not_verified)"], "the WebSocket's ticket would be refused the same way")
        #expect(rig.minting.requests.count == 1)

        // Refused again after a cure: once is all.
        var again = 0
        let twice = Rig(cure: { _, retry in
            again += 1
            retry(true)
        })
        twice.minting.outcome = .refused(status: 403, code: "app_not_verified", message: "No pass.")
        twice.engine.prepare()
        #expect(again == 1)
        #expect(twice.minting.requests.count == 2)
        #expect(twice.names == ["refused(app_not_verified)"])
    }

    @Test func appNotAllowedEndsTheCallAtOnce() {
        var cures = 0
        let rig = Rig(cure: { _, retry in
            cures += 1
            retry(true)
        })
        rig.minting.outcome = .refused(status: 403, code: "app_not_allowed", message: "Not one of the agent's apps.")
        rig.engine.prepare()
        #expect(cures == 0, "final: nothing to cure")
        #expect(rig.names == ["refused(app_not_allowed)"])
        #expect(GraineRtcRefusal.codes.isSuperset(of: ["app_not_allowed", "app_not_verified"]))
        #expect(GraineRtcRefusal.curable == ["app_not_verified", "identity_unverified"])
    }

    /// A grant's renewal is built from the mint body: it carries the app's declaration and the identity's proof as the core sealed them.
    @Test func grantRenewalsCarryTheAppAndAreKeyedByWhoIsCalling() throws {
        let rig = DirectRig()
        func body(appPass: String, token: String, userPass: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "publishableKey": DirectFixture.key, "session_id": "", "installId": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
                "memory": true, "timezone": "Asia/Kolkata", "audio_ready_signal": true,
                "identity": ["value": "customer-1", "token": token, "pass": userPass],
                "app": ["platform": "ios", "id": "com.acme.app", "team": "ABCDE12345", "pass": appPass],
            ])
        }
        var heard: [Int] = []
        rig.mint.warm(baseUrl: DirectFixture.base, body: body(appPass: "ap1.a", token: "t1", userPass: "up1.a"), heard: { status, _ in heard.append(status) })
        let grantOnly = try #require(rig.gateway.sent.first { $0.kind == .grantOnly }?.json)
        #expect(grantOnly["app"] as? [String: String] == ["platform": "ios", "id": "com.acme.app", "team": "ABCDE12345", "pass": "ap1.a"])
        #expect(grantOnly["identity"] as? [String: String] == ["value": "customer-1", "token": "t1", "pass": "up1.a"])
        #expect(grantOnly["grant_only"] as? Bool == true)
        #expect(heard == [200], "the core hears what the web route said")

        // The passes renewed on their own: the same customer, the grant in hand kept, nothing asked.
        rig.mint.warm(baseUrl: DirectFixture.base, body: body(appPass: "ap1.b", token: "t1", userPass: "up1.b"))
        #expect(rig.gateway.sent.filter { $0.kind == .grantOnly }.count == 1)
        #expect(RtcMintBodyParts(body(appPass: "ap1.a", token: "t1", userPass: "up1.a"))!.identityKey
                == RtcMintBodyParts(body(appPass: "ap1.b", token: "t1", userPass: "up1.b"))!.identityKey)

        // Another identity token: who is calling is proven anew — the grant asked for under the old one goes.
        rig.mint.warm(baseUrl: DirectFixture.base, body: body(appPass: "ap1.b", token: "t2", userPass: "up1.b"))
        #expect(rig.gateway.sent.filter { $0.kind == .grantOnly }.count == 2)
        #expect(rig.grant(for: rig.next?.callId) != nil)
    }
}
