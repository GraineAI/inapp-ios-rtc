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
    /**
     * WHAT THE SPEAKER HAS TAKEN, whatever the audio says (the playout watch,
     * RtcCallEngine): the receiver's `totalSamplesReceived`, counted only as
     * the phone's playout pulls audio, and libwebrtc's own `media-playout`
     * count of samples handed to the speaker. Nil where not reported.
     */
    var samplesReceived: Int? = nil
    var playoutSamples: Int? = nil
    /// False when the receiver reports nothing yet (no packet has arrived) and only the playout count is known.
    var inbound = true

    /// "audio/PCMU/8000": the codec and its clock rate, for the voice row (which writes it the SDP way, "PCMU/8000").
    var codecName: String? {
        guard let mime = codec else { return nil }
        return clockRate.map { "\(mime)/\($0)" } ?? mime
    }
}

struct RtcMediaError: Error, Equatable, CustomStringConvertible {
    var description: String
}

/// What the phone's audio route did while a call is live (RtcAudioControl.watchRoute).
enum RtcAudioRouteEvent: Equatable {
    /// The output moved — a headset or a car kit connected or left, the speaker toggled: the kind it is now.
    case changed(String?)
    /// The system interrupted the call's audio (Siri, an alarm)…
    case interrupted
    /// …and gave it back: the kind of output it plays from now.
    case resumed(String?)
}

/// The kind of output an AVAudioSession port is, as an `audio` row says it — never a device's name.
enum RtcAudioRoute {
    static func kind(_ portType: String?) -> String? {
        switch portType {
        case "Speaker"?: return "speaker"
        case "Receiver"?: return "receiver"
        case "BluetoothHFP"?, "BluetoothA2DPOutput"?, "BluetoothLE"?: return "bluetooth"
        case "Headphones"?, "USBAudio"?, "LineOut"?, "HDMIOutput"?: return "wired"
        case "AirPlay"?: return "airplay"
        case "CarAudio"?: return "car"
        default: return nil
        }
    }
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

    // WEAK NETWORKS (RtcMediaRecovery, RtcResilience)

    /// The link's pace (RtcPace): the relay wait of the next gathering grows with it while no UDP path has shown up.
    var gatherPace: Double { get set }
    /// What this peer has gathered since it was made (or since `forgetGathered`), by kind — server-reflexive ones included.
    var gathered: RtcGathered { get }
    /// The network changed: what was gathered says nothing about the new one.
    func forgetGathered()
    /// The connection's checks (candidate pairs, the transport's bytes and DTLS state); nil when they cannot be read.
    func iceStats(_ done: @escaping (RtcIceReading?) -> Void)
    /**
     * Gather on these servers from the next offer on — with `relayOnly`, only
     * through relays (the relays over TCP and TLS a UDP-blocking network
     * leaves). False when the peer refused the change.
     */
    func useServers(_ servers: [RtcIceServer], relayOnly: Bool) -> Bool
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
    /**
     * Audio arrives and nothing plays (the playout watch): start the audio
     * again from the top, activating the session here when it must. False
     * when it would not start.
     */
    func restart() -> Bool
    /// Why nothing plays, as far as the audio session can tell — an `audio` row's reason (`interrupted`, `unit_failed`, `disabled`, `inactive`) — or nil.
    func stallCause() -> String?
    /**
     * Hear the phone's audio route while a call is live — an output that
     * moves (a headset or car kit connecting or leaving, the speaker toggled),
     * an interruption and its end — on any thread. Returns what stops it.
     */
    func watchRoute(_ heard: @escaping (RtcAudioRouteEvent) -> Void) -> () -> Void
    /// The call is over: the app's own audio settings back.
    func callEnds()
}

/// The Mac's (and the tests'): there is no audio session to manage.
final class NoAudioControl: RtcAudioControl {
    func callBegins() {}
    func activated() {}
    func startDirectly() -> Bool { true }
    func deactivated() {}
    func restart() -> Bool { true }
    func stallCause() -> String? { nil }
    func watchRoute(_ heard: @escaping (RtcAudioRouteEvent) -> Void) -> () -> Void { {} }
    func callEnds() {}
}
