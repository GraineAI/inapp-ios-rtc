#if os(iOS)
import AVFoundation
import Foundation
import LiveKitWebRTC
import Testing
@testable import GraineInAppRTC

/*
 * THE REAL AUDIO DEVICE MODULE, ON THE IOS SIMULATOR, NO NETWORK. Nothing here reaches a server: two peers in this
 * process talk to each other. CallKit's activation cannot be proved on a simulator, so the session is activated as
 * the SDK's direct start activates it. What this proves is the claim the fix stands on (RtcAudioGate): after a start
 * that failed, WebRTC does not believe playout or recording started; turning the audio off and on, which is all the
 * old restart did, starts nothing; asking the module directly (retryAudioUnit) does, and the audio plays again.
 *
 * Opt-in, and alone: the process has one audio device module, so any other suite's peers change what these read.
 *   TEST_RUNNER_GRAINE_SIM_AUDIO=1 xcodebuild test -scheme GraineInAppRTC \
 *     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:GraineInAppRTCTests/RtcAudioGateSimulatorTests
 */
private final class LoopbackPeer: NSObject, LKRTCPeerConnectionDelegate {
    private(set) var pc: LKRTCPeerConnection!
    private var gathered: CheckedContinuation<Void, Never>?
    private var complete = false
    private let lock = NSLock()

    override init() {
        super.init()
        let factory = WebRTCMedia.factory()
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        pc = factory.peerConnection(with: config, constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "loopback")
        _ = pc.add(track, streamIds: ["loopback"])
    }

    func answer(_ offer: String) async throws -> String {
        let none = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offer)) { error in
                if let error = error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        let answer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { c in
            pc.answer(for: none) { answer, error in
                if let answer = answer { c.resume(returning: answer) } else { c.resume(throwing: error ?? CancellationError()) }
            }
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { error in
                if let error = error { c.resume(throwing: error) } else { c.resume() }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if complete { lock.unlock(); c.resume(); return }
            gathered = c
            lock.unlock()
        }
        return try #require(pc.localDescription?.sdp)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        guard newState == .complete else { return }
        lock.lock()
        complete = true
        let waiting = gathered
        gathered = nil
        lock.unlock()
        waiting?.resume()
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GRAINE_SIM_AUDIO"] == "1"))
struct RtcAudioGateSimulatorTests {
    private var module: LKRTCAudioDeviceModule { WebRTCMedia.factory().audioDeviceModule }
    private let session = LKRTCAudioSession.sharedInstance()

    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// A failed start leaves this: playout set up, and not believed started.
    @Test func turningTheAudioOffAndOnStartsNothingAndTheRetryDoes() async throws {
        let gate = RtcAudioGate.shared
        let module = self.module
        // The module is ready once a peer exists, as it always is on a call.
        let peer = LoopbackPeer()
        defer { peer.pc.close() }
        gate.callBegins()
        defer { _ = module.stopRecording(); _ = module.stopPlayout(); gate.callEnds() }
        #expect(gate.startDirectly(), "the session activates")
        #expect(module.initPlayout() == 0)
        #expect(module.isPlayoutInitialized)
        #expect(!module.isPlaying, "as a failed start leaves it")

        // What the old restart did, and all it did.
        session.isAudioEnabled = false
        session.isAudioEnabled = true
        await pause(0.6)
        #expect(!module.isPlaying, "off and on starts nothing: WebRTC starts only what it believes is started")
        #expect(!module.isRecording)

        gate.retryAudioUnit()
        await pause(0.3)
        #expect(module.isPlaying, "asked directly, it plays")
        #expect(module.isRecording, "and it records")

        // Asking again starts nothing twice.
        gate.retryAudioUnit()
        await pause(0.2)
        #expect(module.isPlaying && module.isRecording)
    }

    /**
     * A TAPPED CALL DIALS BEFORE ITS AUDIO: everything set up with the audio off starts no audio unit and turns no
     * microphone on; the audio coming on then starts it once, both ways, and it plays. If that start fails, the module
     * believes both running, so the retry goes through the audio going off and on.
     */
    @Test func aCallConnectedBeforeItsAudioPlaysOnceTheAudioComesOn() async throws {
        let gate = RtcAudioGate.shared
        let module = self.module
        gate.callBegins()                          // manual audio, off: as the tap leaves it
        defer { _ = module.stopRecording(); _ = module.stopPlayout(); gate.callEnds() }

        let clock = DispatchRtcClock()
        let media = WebRTCMedia(clock: clock)
        defer { clock.run { media.close() } }
        let peer = LoopbackPeer()
        defer { peer.pc.close() }
        let offer: Result<String, RtcMediaError> = await withCheckedContinuation { c in
            clock.run { media.prepareOffer(iceServers: []) { c.resume(returning: $0) } }
        }
        let answer = try await peer.answer(try offer.get())
        let refused: RtcMediaError? = await withCheckedContinuation { c in
            clock.run { media.applyAnswer(answer) { c.resume(returning: $0) } }
        }
        #expect(refused == nil, "\(String(describing: refused))")
        func played() async -> Int {
            let stats: RtcInboundAudio? = await withCheckedContinuation { c in clock.run { media.inboundAudio { c.resume(returning: $0) } } }
            return (stats?.playoutSamples ?? 0) + (stats?.samplesReceived ?? 0)
        }
        await pause(1.5)
        let before = await played()
        await pause(0.5)
        let still = await played()
        print("audio off: played \(before) → \(still), playing \(module.isPlaying), recording \(module.isRecording)")
        #expect(still == before, "connected with the audio off: nothing plays")
        #expect(gate.stallCause() == "disabled", "and the session says why")

        #expect(gate.startDirectly(), "the audio comes on (CallKit's activation can't run on a simulator)")
        var running = false
        for _ in 0..<30 {
            let from = await played()
            await pause(0.2)
            let to = await played()
            if to > from { running = true; print("audio on: played \(from) → \(to)"); break }
        }
        #expect(running, "and it plays, with nothing else asked")
        #expect(module.isPlaying && module.isRecording, "both ways")

        // The retry when both are believed running: off and on, and it plays again.
        gate.retryAudioUnit()
        await pause(0.5)
        let from = await played()
        await pause(0.5)
        let to = await played()
        print("after the retry: played \(from) → \(to)")
        #expect(to > from, "the retry brings it back")
    }

    /// Real audio between two peers: the speaker's count stops with playout, off and on does not restart it, the retry does.
    @Test func aCallsAudioStoppedByAFailedStartPlaysAgainAfterTheRetry() async throws {
        let gate = RtcAudioGate.shared
        let module = self.module
        gate.callBegins()
        defer { _ = module.stopRecording(); _ = module.stopPlayout(); gate.callEnds() }
        #expect(gate.startDirectly())

        let clock = DispatchRtcClock()
        let media = WebRTCMedia(clock: clock)
        defer { clock.run { media.close() } }
        let peer = LoopbackPeer()
        defer { peer.pc.close() }
        let offer: Result<String, RtcMediaError> = await withCheckedContinuation { c in
            clock.run { media.prepareOffer(iceServers: []) { c.resume(returning: $0) } }
        }
        let answer = try await peer.answer(try offer.get())
        let refused: RtcMediaError? = await withCheckedContinuation { c in
            clock.run { media.applyAnswer(answer) { c.resume(returning: $0) } }
        }
        #expect(refused == nil, "\(String(describing: refused))")

        func counts() async -> (played: Int, received: Int, packets: Int) {
            let stats: RtcInboundAudio? = await withCheckedContinuation { c in clock.run { media.inboundAudio { c.resume(returning: $0) } } }
            return (stats?.playoutSamples ?? 0, stats?.samplesReceived ?? 0, stats?.packetsReceived ?? 0)
        }
        func grows(_ seconds: Double) async -> Bool {
            let before = await counts()
            await pause(seconds)
            let after = await counts()
            print("audio counts: played \(before.played) → \(after.played), received \(before.received) → \(after.received), packets \(before.packets) → \(after.packets)")
            return after.played > before.played || after.received > before.received
        }

        // The call's audio runs.
        var running = false
        for _ in 0..<30 {
            if !module.isPlaying { _ = module.startPlayout() }
            if await grows(0.5) { running = true; break }
        }
        #expect(running, "the audio plays between the two peers")
        #expect(module.isPlaying)

        // The state a failed start leaves.
        _ = module.stopRecording()
        _ = module.stopPlayout()
        await pause(0.5)
        #expect(!module.isPlaying)
        #expect(await !grows(1.0), "nothing plays")

        // The old restart: off and on.
        session.isAudioEnabled = false
        session.isAudioEnabled = true
        await pause(0.5)
        #expect(!module.isPlaying, "off and on starts nothing")
        #expect(await !grows(1.0), "still nothing plays")

        // The fix.
        gate.retryAudioUnit()
        await pause(0.5)
        #expect(module.isPlaying)
        #expect(await grows(1.5), "the audio plays again")
    }
}
#endif
