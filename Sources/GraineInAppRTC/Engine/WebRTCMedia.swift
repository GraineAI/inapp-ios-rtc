import Foundation
import LiveKitWebRTC

/*
 * THE REAL MEDIA: Google's libwebrtc, prebuilt with every class prefixed
 * (LKRTC…), so it never collides with another copy of WebRTC in the same app.
 * Only this file knows the binary: a different build of libwebrtc replaces
 * it without touching the SIP user agent or the engine (RtcMedia is the seam).
 *
 * One peer connection per call, configured as the voice bar's browser runs
 * it: the mint's ICE servers, unified plan, the BALANCED bundle policy (the
 * SBC answers with no BUNDLE group, which max-bundle refuses outright —
 * "Answer cannot remove m= section … from already-established BUNDLE group";
 * with one m-line the offer is the same either way), RTCP mux required,
 * gathering continually, a candidate pool of one, one sendrecv audio
 * transceiver. The SBC never
 * trickles, so the offer leaves complete — with what the voice bar's rule
 * (IceGathering) says is enough — and its codecs are listed Opus first, then
 * PCMU (the SBC answers PCMU today; telephone-event/8000 rides along).
 *
 * WebRTC's callbacks arrive on its own threads; every result hops onto the
 * engine's clock before anything is decided.
 */
final class WebRTCMedia: NSObject, RtcMedia, LKRTCPeerConnectionDelegate {
    /// How the process's one factory is built. Set before the first call; the Mac's live test renders without a speaker.
    struct FactoryOptions {
        /// The library's AVAudioEngine device module instead of the platform's.
        var audioEngine = false
        /// Render without audio hardware (the AVAudioEngine module only).
        var manualRendering = false
    }

    static var factoryOptions = FactoryOptions()
    private static let factoryLock = NSLock()
    private static var sharedFactory: LKRTCPeerConnectionFactory?

    /// The factory, made once per process: its audio device module belongs to the whole app.
    static func factory() -> LKRTCPeerConnectionFactory {
        factoryLock.lock()
        defer { factoryLock.unlock() }
        if let made = sharedFactory { return made }
        _ = LKRTCInitializeSSL()
        let made = LKRTCPeerConnectionFactory(
            audioDeviceModuleType: factoryOptions.audioEngine ? .audioEngine : .platformDefault,
            bypassVoiceProcessing: false,
            encoderFactory: nil,
            decoderFactory: nil,
            audioProcessingModule: nil
        )
        if factoryOptions.audioEngine && factoryOptions.manualRendering {
            _ = made.audioDeviceModule.setManualRenderingMode(true)
        }
        sharedFactory = made
        return made
    }

    var onIceState: ((RtcIceState) -> Void)?

    private let clock: RtcClock
    private var peer: LKRTCPeerConnection?
    private var track: LKRTCAudioTrack?
    private var servers: [RtcIceServer] = []
    private var gathering: Gathering?
    /// Muted before the track existed: applied when it does.
    private var muted = false

    /// The rule's state while an offer gathers.
    private struct Gathering {
        var started: Double
        var cap: Double
        var wantRelay: Bool
        var timer: RtcTimer?
        var done: (Result<String, RtcMediaError>) -> Void
    }

    init(clock: RtcClock) {
        self.clock = clock
        super.init()
    }

    // MARK: - RtcMedia

    func prepareOffer(iceServers: [RtcIceServer], done: @escaping (Result<String, RtcMediaError>) -> Void) {
        let factory = Self.factory()
        servers = iceServers
        let config = LKRTCConfiguration()
        config.iceServers = iceServers.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        // Not max-bundle: the SBC's answer has no BUNDLE group (see above), and Chrome's default takes it.
        config.bundlePolicy = .balanced
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.iceCandidatePoolSize = 1
        let none = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: none, delegate: self) else {
            done(.failure(RtcMediaError(description: "the peer connection could not be made")))
            return
        }
        self.peer = peer
        let source = factory.audioSource(with: none)
        let track = factory.audioTrack(with: source, trackId: "graine-call-audio")
        track.isEnabled = !muted
        self.track = track
        let initial = LKRTCRtpTransceiverInit()
        initial.direction = .sendRecv
        initial.streamIds = ["graine-call"]
        guard peer.addTransceiver(with: track, init: initial) != nil else {
            done(.failure(RtcMediaError(description: "the audio transceiver could not be added")))
            return
        }
        offer(iceRestart: false, gather: true, done: done)
    }

    func applyAnswer(_ sdp: String, done: @escaping (RtcMediaError?) -> Void) {
        guard let peer = peer else {
            done(RtcMediaError(description: "no peer connection"))
            return
        }
        peer.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
            self?.clock.run { done(error.map { RtcMediaError(description: "the answer was refused: \($0.localizedDescription)") }) }
        }
    }

    func answer(offer sdp: String, done: @escaping (Result<String, RtcMediaError>) -> Void) {
        guard let peer = peer else {
            done(.failure(RtcMediaError(description: "no peer connection")))
            return
        }
        peer.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.clock.run { done(.failure(RtcMediaError(description: "their offer was refused: \(error.localizedDescription)"))) }
                return
            }
            peer.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                guard let answer = answer else {
                    self.clock.run { done(.failure(RtcMediaError(description: "no answer: \(error?.localizedDescription ?? "unknown")"))) }
                    return
                }
                peer.setLocalDescription(answer) { error in
                    self.clock.run {
                        if let error = error {
                            done(.failure(RtcMediaError(description: "our answer was refused: \(error.localizedDescription)")))
                        } else {
                            done(.success(SdpCodecs.prefer(peer.localDescription?.sdp ?? answer.sdp)))
                        }
                    }
                }
            }
        }
    }

    func reoffer(iceRestart: Bool, done: @escaping (Result<String, RtcMediaError>) -> Void) {
        // A restart gathers new candidates, by the same rule; a plain re-offer has them already.
        offer(iceRestart: iceRestart, gather: iceRestart, done: done)
    }

    func inboundAudio(_ done: @escaping (RtcInboundAudio?) -> Void) {
        guard let peer = peer else {
            done(nil)
            return
        }
        peer.statistics { report in
            var found: RtcInboundAudio?
            var codecId: String?
            for stat in report.statistics.values where stat.type == "inbound-rtp" {
                guard (stat.values["kind"] as? String ?? stat.values["mediaType"] as? String) == "audio" else { continue }
                func number(_ key: String) -> Double { (stat.values[key] as? NSNumber)?.doubleValue ?? 0 }
                found = RtcInboundAudio(
                    audioLevel: number("audioLevel"),
                    totalAudioEnergy: number("totalAudioEnergy"),
                    bytesReceived: Int(number("bytesReceived")),
                    packetsReceived: Int(number("packetsReceived")),
                    packetsLost: Int(number("packetsLost")),
                    jitter: number("jitter"),
                    codec: nil
                )
                codecId = stat.values["codecId"] as? String
            }
            if var audio = found, let id = codecId, let codec = report.statistics[id] {
                audio.codec = codec.values["mimeType"] as? String
                found = audio
            }
            // The pair ICE chose: which kind of path the call took, and how long a round trip is on it.
            if var audio = found,
               let pair = report.statistics.values.first(where: { $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true && ($0.values["state"] as? String) == "succeeded" }) {
                func type(_ key: String) -> String {
                    (pair.values[key] as? String).flatMap { report.statistics[$0]?.values["candidateType"] as? String } ?? "?"
                }
                audio.path = "\(type("localCandidateId")) → \(type("remoteCandidateId"))"
                audio.roundTrip = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
                found = audio
            }
            done(found)
        }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        track?.isEnabled = !muted
    }

    func close() {
        gathering?.timer?.cancel()
        gathering = nil
        onIceState = nil
        peer?.close()
        peer = nil
        track = nil
    }

    // MARK: - The offer, and when it is complete enough

    private func offer(iceRestart: Bool, gather: Bool, done: @escaping (Result<String, RtcMediaError>) -> Void) {
        guard let peer = peer else {
            done(.failure(RtcMediaError(description: "no peer connection")))
            return
        }
        var mandatory = [
            kLKRTCMediaConstraintsOfferToReceiveAudio: kLKRTCMediaConstraintsValueTrue,
            kLKRTCMediaConstraintsOfferToReceiveVideo: kLKRTCMediaConstraintsValueFalse,
        ]
        if iceRestart { mandatory[kLKRTCMediaConstraintsIceRestart] = kLKRTCMediaConstraintsValueTrue }
        peer.offer(for: LKRTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)) { [weak self] offer, error in
            guard let self = self else { return }
            guard let offer = offer else {
                self.clock.run { done(.failure(RtcMediaError(description: "no offer: \(error?.localizedDescription ?? "unknown")"))) }
                return
            }
            peer.setLocalDescription(offer) { error in
                self.clock.run {
                    if let error = error {
                        done(.failure(RtcMediaError(description: "our offer was refused: \(error.localizedDescription)")))
                    } else if gather {
                        self.gather(done)
                    } else {
                        done(.success(SdpCodecs.prefer(peer.localDescription?.sdp ?? offer.sdp)))
                    }
                }
            }
        }
    }

    /// On the clock: wait for the rule, then hand over the description as it stands, candidates inside.
    private func gather(_ done: @escaping (Result<String, RtcMediaError>) -> Void) {
        gathering?.timer?.cancel()
        let cap = IceGathering.cap(for: servers)
        var state = Gathering(started: clock.now, cap: cap, wantRelay: IceGathering.hasTurn(servers), done: done)
        state.timer = clock.after(cap) { [weak self] in self?.endGathering() }
        gathering = state
        // The pool may have them already: judge what the description holds before waiting for more.
        for line in (peer?.localDescription?.sdp ?? "").components(separatedBy: "\n") where line.hasPrefix("a=candidate:") {
            consider(IceGathering.kind(String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if peer?.iceGatheringState == .complete { consider(.end) }
    }

    private func consider(_ kind: IceCandidateKind) {
        guard let state = gathering else { return }
        if IceGathering.endNow(kind, elapsed: clock.now - state.started, cap: state.cap, wantRelay: state.wantRelay) {
            endGathering()
        }
    }

    private func endGathering() {
        guard let state = gathering else { return }
        gathering = nil
        state.timer?.cancel()
        guard let sdp = peer?.localDescription?.sdp else {
            state.done(.failure(RtcMediaError(description: "the offer vanished while it gathered")))
            return
        }
        state.done(.success(SdpCodecs.prefer(sdp)))
    }

    // MARK: - LKRTCPeerConnectionDelegate (WebRTC's threads)

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        let state: RtcIceState
        switch newState {
        case .new: state = .new
        case .checking: state = .checking
        case .connected: state = .connected
        case .completed: state = .completed
        case .failed: state = .failed
        case .disconnected: state = .disconnected
        case .closed: state = .closed
        default: return
        }
        clock.run { [weak self] in self?.onIceState?(state) }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        guard newState == .complete else { return }
        clock.run { [weak self] in self?.consider(.end) }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let kind = IceGathering.kind(candidate.sdp)
        clock.run { [weak self] in self?.consider(kind) }
    }
}
