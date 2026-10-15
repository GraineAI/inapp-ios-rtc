#if os(iOS)
import AVFoundation
import LiveKitWebRTC

/**
 * THE CALL'S AUDIO SESSION, AS CALLKIT HANDS IT OVER.
 *
 * Under CallKit the system activates the app's audio session, and says so in
 * `provider(_:didActivate:)`. WebRTC must not start the microphone or the
 * speaker before that, or a call prepared while it rings would take the
 * microphone from whatever the phone was doing, and the agent's greeting would
 * be played into a session that is not running (and lost). So, while a WebRTC
 * call is live, WebRTC's audio is manual and off until CallKit activates the
 * session; then it is told so, configured for a call (play and record, voice
 * chat, Bluetooth headsets) inside its own lock, and enabled — and only then
 * does the INVITE leave. Manual audio only while the call lasts: an app that
 * uses the same library for something else gets its settings back.
 */
final class RtcAudioGate: RtcAudioControl {
    static let shared = RtcAudioGate()

    private let lock = NSLock()
    private var saved: (manual: Bool, enabled: Bool)?

    private var session: LKRTCAudioSession { LKRTCAudioSession.sharedInstance() }

    func callBegins() {
        lock.lock()
        defer { lock.unlock() }
        if saved == nil { saved = (session.useManualAudio, session.isAudioEnabled) }
        session.useManualAudio = true
        session.isAudioEnabled = false
    }

    func activated() {
        session.audioSessionDidActivate(AVAudioSession.sharedInstance())
        configure(activate: false)
        session.isAudioEnabled = true
    }

    func startDirectly() -> Bool {
        guard configure(activate: true) else { return false }
        session.isAudioEnabled = true
        return true
    }

    func deactivated() {
        session.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        session.isAudioEnabled = false
    }

    func callEnds() {
        lock.lock()
        defer { lock.unlock() }
        session.isAudioEnabled = false
        if let saved = saved {
            session.useManualAudio = saved.manual
            session.isAudioEnabled = saved.enabled
        }
        saved = nil
    }

    /// Play and record, voice chat, Bluetooth headsets — inside WebRTC's lock, so its own view of the session agrees.
    @discardableResult
    private func configure(activate: Bool) -> Bool {
        // The same option (0x4) under two names: Xcode 26 (Swift 6.2) renamed allowBluetooth to allowBluetoothHFP.
        #if compiler(>=6.2)
        let bluetooth: AVAudioSession.CategoryOptions = .allowBluetoothHFP
        #else
        let bluetooth: AVAudioSession.CategoryOptions = .allowBluetooth
        #endif
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [bluetooth])
            if activate { try session.setActive(true) }
            return true
        } catch {
            return false
        }
    }
}
#endif
