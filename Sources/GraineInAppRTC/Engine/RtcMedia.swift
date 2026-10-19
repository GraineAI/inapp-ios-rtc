import Foundation

/*
 * THE CALL'S MEDIA, BEHIND ONE SEAM — so the engine's whole sequence (the
 * mint, the registration, the dial, the deadlines, the fallback) is proven on
 * a Mac with a scripted peer, and the real one (WebRTCMedia, libwebrtc) is
 * the only thing that needs a device or the live test.
 */

enum RtcIceState: String, Equatable {
    case new, checking, connected, completed, failed, disconnected, closed
}

/// What the receiver's statistics say about the agent's voice.
struct RtcInboundAudio: Equatable {
    /// 0…1, the level of what is being played out now.
    var audioLevel: Double
    /// Σ level² × seconds, since the call began.
    var totalAudioEnergy: Double
    var bytesReceived: Int
    var packetsReceived: Int
    var packetsLost: Int
    var jitter: Double
    /// "audio/PCMU", "audio/opus" — once known.
    var codec: String?
    /// The path in use, "relay → host" (ours → theirs), and its round trip in seconds — once ICE has chosen one.
    var path: String? = nil
    var roundTrip: Double? = nil
    /// The codec's clock rate (8000, 48000) — once known.
    var clockRate: Int? = nil
    /// Our side of that path: "host", "srflx", "prflx" or "relay".
    var candidate: String? = nil

    /// "audio/PCMU/8000": the codec and its clock rate, for the voice row (which writes it the SDP way, "PCMU/8000").
    var codecName: String? {
        guard let mime = codec else { return nil }
        return clockRate.map { "\(mime)/\($0)" } ?? mime
    }
}

struct RtcMediaError: Error, Equatable, CustomStringConvertible {
    var description: String
}

protocol RtcMedia: AnyObject {
    /// The ICE connection's state, as it changes, on any thread.
    var onIceState: ((RtcIceState) -> Void)? { get set }
    /**
     * Build the peer for these servers (one sendrecv audio transceiver, the
     * balanced bundle policy, RTCP mux required, gathering continually, a pool of one), make
     * the offer and gather until the voice bar's rule says enough; `done` gets
     * the offer to send, candidates inside.
     */
    func prepareOffer(iceServers: [RtcIceServer], done: @escaping (Result<String, RtcMediaError>) -> Void)
    func applyAnswer(_ sdp: String, done: @escaping (RtcMediaError?) -> Void)
    /// Their offer inside the call (a session refresh): our answer.
    func answer(offer sdp: String, done: @escaping (Result<String, RtcMediaError>) -> Void)
    /// Offer again inside the call: with new ICE credentials for a restart, or as it stands.
    func reoffer(iceRestart: Bool, done: @escaping (Result<String, RtcMediaError>) -> Void)
    func inboundAudio(_ done: @escaping (RtcInboundAudio?) -> Void)
    /// The microphone's track on or off; capture keeps running.
    func setMuted(_ muted: Bool)
    func close()
}

/**
 * The phone's audio session, under CallKit (WEBRTC-CALLS §2): WebRTC is told
 * to leave the audio alone until CallKit hands it over, so a call prepared
 * while it rings never touches the microphone, and the greeting is never
 * played into an audio session that is not running yet. Nothing on a Mac.
 */
protocol RtcAudioControl: AnyObject {
    /// A WebRTC call begins: manual audio, disabled.
    func callBegins()
    /// CallKit activated the session: tell WebRTC, configure it, enable the audio.
    func activated()
    /// CallKit never did: activate it here. False when it would not start.
    func startDirectly() -> Bool
    /// CallKit took the session back (a hold, an interruption).
    func deactivated()
    /// The call is over: the app's own audio settings back.
    func callEnds()
}

/// The Mac's (and the tests'): there is no audio session to manage.
final class NoAudioControl: RtcAudioControl {
    func callBegins() {}
    func activated() {}
    func startDirectly() -> Bool { true }
    func deactivated() {}
    func callEnds() {}
}
