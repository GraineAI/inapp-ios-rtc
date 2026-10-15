import Foundation
import Testing
@testable import GraineInAppRTC

/*
 * THE REAL PEER, NO NETWORK: libwebrtc itself makes the offer and takes the
 * SBC's answer exactly as production sends it (TRACE.md §3). The SBC answers
 * PCMU at payload 0 with telephone-event/8000 at 126, full ICE, no BUNDLE
 * group, setup:active — the offer must carry both, and the answer must apply
 * (it does under the browser's balanced bundle policy; max-bundle refuses it).
 */
@Suite(.serialized) struct WebRTCMediaTests {
    private func offer(_ media: WebRTCMedia, clock: DispatchRtcClock) async -> Result<String, RtcMediaError> {
        await withCheckedContinuation { continuation in
            clock.run { media.prepareOffer(iceServers: []) { continuation.resume(returning: $0) } }
        }
    }

    @Test func theOfferCarriesWhatTheSbcAnswersAndItsAnswerApplies() async throws {
        let clock = DispatchRtcClock()
        let media = WebRTCMedia(clock: clock)
        let began = Date()
        let sdp = try await offer(media, clock: clock).get()
        let waited = Date().timeIntervalSince(began)
        let lines = sdp.components(separatedBy: "\r\n")
        let mline = try #require(lines.first { $0.hasPrefix("m=audio") })
        let formats = mline.split(separator: " ").dropFirst(3).map(String.init)
        #expect(formats.first == "111", "Opus first")
        #expect(formats.dropFirst().first == "0", "then PCMU")
        #expect(lines.contains("a=rtpmap:0 PCMU/8000"))
        #expect(lines.contains("a=rtpmap:126 telephone-event/8000"), "the SBC answers telephone-event at 126")
        #expect(lines.contains("a=group:BUNDLE 0"))
        #expect(lines.contains("a=rtcp-mux"))
        #expect(lines.contains("a=setup:actpass"))
        #expect(lines.contains("a=sendrecv"))
        #expect(lines.filter { $0.hasPrefix("m=") }.count == 1, "one audio section, nothing else")
        #expect(lines.contains { $0.hasPrefix("a=candidate:") }, "complete: candidates inside")
        #expect(waited < 3, "the gathering rule ends the wait (\(waited) s)")

        let refused: RtcMediaError? = await withCheckedContinuation { continuation in
            clock.run { media.applyAnswer(TraceSdp.answer) { continuation.resume(returning: $0) } }
        }
        #expect(refused == nil, "\(String(describing: refused))")
        clock.run { media.close() }
    }

    @Test func anIceRestartOffersNewCredentials() async throws {
        let clock = DispatchRtcClock()
        let media = WebRTCMedia(clock: clock)
        let first = try await offer(media, clock: clock).get()
        let refused: RtcMediaError? = await withCheckedContinuation { continuation in
            clock.run { media.applyAnswer(TraceSdp.answer) { continuation.resume(returning: $0) } }
        }
        try #require(refused == nil)
        let restart: Result<String, RtcMediaError> = await withCheckedContinuation { continuation in
            clock.run { media.reoffer(iceRestart: true) { continuation.resume(returning: $0) } }
        }
        let second = try restart.get()
        func ufrag(_ sdp: String) -> String? { sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("a=ice-ufrag:") } }
        #expect(ufrag(first) != nil)
        #expect(ufrag(second) != ufrag(first), "new ICE credentials")
        clock.run { media.close() }
    }
}
