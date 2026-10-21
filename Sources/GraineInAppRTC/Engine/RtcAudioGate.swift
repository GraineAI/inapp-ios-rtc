#if os(iOS)
import AVFoundation
import LiveKitWebRTC
import os.log

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
 * uses the same library for something else gets its settings back — once the
 * last leg holding the gate lets it go (a call prepared before the tap, a
 * ring's, another agent's may overlap).
 *
 * WHEN CALLKIT NEVER ACTIVATES IT (the call's 3 s rescue, `startDirectly`):
 * the session is activated HERE, on AVAudioSession itself — never through
 * WebRTC's own `setActive`, which skips the activation when WebRTC still
 * believes the last call's session active — and WebRTC is told, as CallKit's
 * activation tells it. A session activated here is deactivated here when the
 * last leg ends: CallKit, which never activated it, will not, and a session
 * the app keeps active is one CallKit never hands the next call. Every step
 * says what happened in the log (subsystem ai.graine.inapp, category GraineRTC).
 */
final class RtcAudioGate: RtcAudioControl {
    static let shared = RtcAudioGate()

    private static let log = OSLog(subsystem: "ai.graine.inapp", category: "GraineRTC")

    private let lock = NSLock()
    private var saved: (manual: Bool, enabled: Bool)?
    /// The legs holding the gate now.
    private var holders = 0
    /// The session was activated here (the rescue), not by CallKit: it is let go of here.
    private var activatedHere = false

    private var session: LKRTCAudioSession { LKRTCAudioSession.sharedInstance() }

    func callBegins() {
        lock.lock()
        defer { lock.unlock() }
        if holders == 0 { saved = (session.useManualAudio, session.isAudioEnabled) }
        holders += 1
        session.useManualAudio = true
        session.isAudioEnabled = false
    }

    func activated() {
        session.audioSessionDidActivate(AVAudioSession.sharedInstance())
        configure()
        enable()
        Self.note("CallKit activated the call's audio: WebRTC's audio is on.")
    }

    func startDirectly() -> Bool {
        let audio = AVAudioSession.sharedInstance()
        session.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [Self.bluetooth])
            try audio.setActive(true, options: [])
        } catch {
            session.unlockForConfiguration()
            Self.warn("the call's audio could not be started directly: \(Self.describe(error))")
            return false
        }
        session.unlockForConfiguration()
        lock.lock()
        activatedHere = true
        lock.unlock()
        // Told as CallKit's activation tells it: active, and any interruption it held over from the ring is over.
        session.audioSessionDidActivate(audio)
        enable()
        Self.note("the call's audio was started directly (CallKit never activated it): WebRTC's audio is on.")
        return true
    }

    func deactivated() {
        session.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        session.isAudioEnabled = false
    }

    func callEnds() {
        lock.lock()
        defer { lock.unlock() }
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        session.isAudioEnabled = false
        if activatedHere {
            activatedHere = false
            // A moment on, once WebRTC's audio has stopped (a session with audio running cannot be deactivated) —
            // and only if no call has begun since.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.letGoOfDirectSession() }
        }
        if let saved = saved {
            session.useManualAudio = saved.manual
            session.isAudioEnabled = saved.enabled
        }
        saved = nil
    }

    /// The session the rescue activated, deactivated: CallKit, which never activated it, will not — and hands no next call a session the app holds.
    private func letGoOfDirectSession() {
        lock.lock()
        let idle = holders == 0
        lock.unlock()
        guard idle else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setActive(false, options: [.notifyOthersOnDeactivation])
            Self.note("the audio session started directly for the call was let go of.")
        } catch {
            Self.warn("the audio session started directly for the call could not be let go of: \(Self.describe(error))")
        }
        if session.isActive { session.audioSessionDidDeactivate(audio) }
    }

    /**
     * CallKit took the session back after the call it was for was over, with
     * no leg left to tell (GraineRtcModule.audioSessionDeactivated): WebRTC
     * stops believing it active, or the next call's start trusts a session
     * that is not.
     */
    func sessionDeactivated() {
        lock.lock()
        let idle = holders == 0
        lock.unlock()
        if session.isActive { session.audioSessionDidDeactivate(AVAudioSession.sharedInstance()) }
        if idle { session.isAudioEnabled = false }
    }

    /// On — and started afresh when it already was: an audio unit that could not start against a session not yet active runs now.
    private func enable() {
        if session.isAudioEnabled { session.isAudioEnabled = false }
        session.isAudioEnabled = true
    }

    /// Play and record, voice chat, Bluetooth headsets — inside WebRTC's lock, so its own view of the session agrees.
    private func configure() {
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [Self.bluetooth])
        } catch {
            Self.warn("the call's audio session could not be configured: \(Self.describe(error))")
        }
    }

    /// The same option (0x4) under two names: Xcode 26 (Swift 6.2) renamed allowBluetooth to allowBluetoothHFP.
    private static var bluetooth: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        return .allowBluetoothHFP
        #else
        return .allowBluetooth
        #endif
    }

    /// An audio session error as a log can read it: its domain, code (and four-character code), and sentence.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var code = "\(ns.code)"
        let value = UInt32(truncatingIfNeeded: ns.code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ (32...126).contains($0) }) { code += " '\(String(decoding: bytes, as: UTF8.self))'" }
        return "\(ns.domain) \(code): \(ns.localizedDescription)"
    }

    private static func note(_ line: String) {
        os_log("%{public}@", log: log, type: .default, "Calls: " + line)
    }

    private static func warn(_ line: String) {
        os_log("%{public}@", log: log, type: .error, "warning: Calls: " + line)
    }
}
#endif
