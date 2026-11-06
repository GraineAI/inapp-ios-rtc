import AVFoundation
import Foundation
import Testing
@_spi(GraineRTC) import GraineInApp
@testable import GraineInAppRTC
import LiveKitWebRTC

/*
 * THE AGENT'S FACE ON THE REAL LIBWEBRTC, NO NETWORK: the viewer's offer is
 * what the face's service answers (audio and video received only, the data
 * channel, complete), a second peer standing in for the service applies it and
 * answers, and the call's media keeps measuring the agent's voice while its
 * volume is down.
 */
@Suite(.serialized) struct AvatarViewerTests {
    private func offer(_ viewer: WebRTCAvatarViewer) async -> (String?, String?) {
        await withCheckedContinuation { continuation in
            viewer.offer(iceServers: [], gatherSeconds: 2) { sdp, error in continuation.resume(returning: (sdp, error)) }
        }
    }

    @Test func theOfferReceivesAudioAndVideoAndCarriesTheClocksChannel() async throws {
        let viewer = WebRTCAvatarViewer()
        let (sdp, error) = await offer(viewer)
        #expect(error == nil)
        let lines = try #require(sdp).components(separatedBy: "\r\n")
        #expect(lines.filter { $0.hasPrefix("m=audio") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("m=video") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("m=application") }.count == 1, "the data channel")
        #expect(lines.filter { $0 == "a=recvonly" }.count == 2, "nothing is sent")
        #expect(!lines.contains("a=sendrecv") && !lines.contains("a=sendonly"))
        #expect(lines.contains { $0.hasPrefix("a=rtpmap:") && ($0.contains("VP8/90000") || $0.contains("H264/90000")) },
                "a codec the service sends")
        #expect(lines.contains { $0.hasPrefix("a=candidate:") }, "complete: the service never trickles")

        // A second peer stands in for the service: it takes the offer and its answer applies.
        let service = ServicePeer()
        let answer = try await service.answer(try #require(sdp))
        let applied: String? = await withCheckedContinuation { continuation in
            viewer.applyAnswer(answer) { continuation.resume(returning: $0) }
        }
        #expect(applied == nil)
        viewer.setAudible(true)
        viewer.setAudible(false)
        viewer.send(#"{"type":"ping"}"#)
        let sample: (Double?, Double?) = await withCheckedContinuation { continuation in
            viewer.sample { frames, face, _, _ in continuation.resume(returning: (frames, face)) }
        }
        #expect(sample.1 == 0, "no sound yet")
        viewer.close()
        viewer.close()
        service.close()
        let after: Double?? = await withCheckedContinuation { continuation in
            viewer.sample { frames, _, _, _ in continuation.resume(returning: frames) }
        }
        #expect(after == .some(nil), "closed: nothing to read")
    }

    @Test func theMeterReadsBeforeTheVolume() throws {
        let meter = AudioLevelMeter()
        #expect(meter.meterLevel() == 0 && meter.peakLevel() == 0)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let p = try #require(buffer.int16ChannelData)[0]
        for i in 0..<480 { p[i] = i % 2 == 0 ? 8192 : -8192 }
        meter.render(pcmBuffer: buffer)
        #expect(meter.peakLevel() == 0.25)
        #expect(meter.meterLevel() == 1, "mean |x| 0.25 is the top of the meter scale")
        #expect(AudioLevelMeter.meterScale(0.01) == 0.2)
    }

    @Test func theCallsVoiceIsMeasuredWhileSilenced() async throws {
        let clock = DispatchRtcClock()
        let media = WebRTCMedia(clock: clock)
        #expect(media.agentLevelBeforeMute == nil, "nothing received yet")
        media.setAgentAudible(false)
        let _: Result<String, RtcMediaError> = await withCheckedContinuation { continuation in
            clock.run { media.prepareOffer(iceServers: []) { continuation.resume(returning: $0) } }
        }
        #expect(media.agentLevelBeforeMute == 0, "measured, and quiet")
        media.setAgentAudible(true)
        clock.sync { media.close() }
    }
}

/// libwebrtc as the face's service: answers an offer with audio, video and the data channel.
private final class ServicePeer: NSObject, LKRTCPeerConnectionDelegate {
    private var peer: LKRTCPeerConnection?

    func answer(_ offer: String) async throws -> String {
        let factory = WebRTCMedia.factory()
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let none = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let peer = try #require(factory.peerConnection(with: config, constraints: none, delegate: self))
        self.peer = peer
        try await peer.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offer))
        let answer = try await peer.answer(for: none)
        try await peer.setLocalDescription(answer)
        return answer.sdp
    }

    func close() { peer?.close() }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}
