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
 *
 * WHEN AUDIO ARRIVES AND NOTHING PLAYS (the leg's playout watch, `restart`):
 * WebRTC is told afresh that the session is active — which also ends an
 * interruption it still believes in: one that began after CallKit's
 * activation is never ended on a locked phone, where only the app coming to
 * the front would end it — and its audio unit is made again, the session
 * activated here as the rescue activates it. What WebRTC reported meanwhile
 * (an interruption, an audio unit that would not start) is the restart's
 * reason, for the call's `audio` row.
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
    /// What WebRTC says of the session as it goes: held strongly here, as WebRTC holds its delegates weakly.
    private let reports = RtcAudioSessionReports()

    private var session: LKRTCAudioSession { LKRTCAudioSession.sharedInstance() }

    private init() {
        session.add(reports)
    }

    func callBegins() {
        lock.lock()
        defer { lock.unlock() }
        if holders == 0 {
            saved = (session.useManualAudio, session.isAudioEnabled)
            // No call holds the gate, yet WebRTC still believes a session active: the last call's, its deactivation never
            // told (or told to a leg already gone). Forgotten now, so that THIS call's activation is the one it trusts.
            // The session itself is not touched: CallKit may be activating it for this call this very moment.
            if session.isActive {
                session.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
                Self.note("a previous call's audio session was still believed active: reset before this call.")
            }
        }
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
        guard activateHere() else { return false }
        Self.note("the call's audio was started directly (CallKit never activated it): WebRTC's audio is on.")
        return true
    }

    func restart() -> Bool {
        // Balanced: the activation below tells WebRTC the session is active again, and ends any interruption it holds.
        if session.isActive { session.audioSessionDidDeactivate(AVAudioSession.sharedInstance()) }
        guard activateHere() else { return false }
        Self.note("audio arrived and nothing played: WebRTC's audio was started again.")
        return true
    }

    /**
     * The route as iOS reports it — every route change (a Bluetooth headset or
     * car kit connecting or leaving, the speaker toggled), and an
     * interruption's start and end — with the output's kind now. Posted on a
     * system thread; the leg hops to its own.
     */
    func watchRoute(_ heard: @escaping (RtcAudioRouteEvent) -> Void) -> () -> Void {
        let center = NotificationCenter.default
        let audio = AVAudioSession.sharedInstance()
        let kindNow = { RtcAudioRoute.kind(audio.currentRoute.outputs.first?.portType.rawValue) }
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
            heard(.changed(kindNow()))
        }
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            heard(type == .began ? .interrupted : .resumed(kindNow()))
        }
        return {
            center.removeObserver(route)
            center.removeObserver(interruption)
        }
    }

    func stallCause() -> String? {
        if reports.interrupted { return "interrupted" }
        if reports.unitFailed { return "unit_failed" }
        if !session.isAudioEnabled { return "disabled" }
        if !session.isActive { return "inactive" }
        return nil
    }

    /// The session activated here, on AVAudioSession itself, and WebRTC told as CallKit's activation tells it; its audio enabled afresh.
    private func activateHere() -> Bool {
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
        reports.unitFailed = false
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

/**
 * WebRTC's own word on the session, from its delegate (on a system or WebRTC
 * thread): an interruption that began and has not ended — WebRTC stops its
 * audio unit then and ignores every change until it ends — and an audio unit
 * that would not start. Read for a restart's reason; logged as they come.
 */
private final class RtcAudioSessionReports: NSObject, LKRTCAudioSessionDelegate {
    private let lock = NSLock()
    private var interruptedNow = false
    private var unitFailedNow = false
    private static let log = OSLog(subsystem: "ai.graine.inapp", category: "GraineRTC")

    var interrupted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interruptedNow
    }

    var unitFailed: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return unitFailedNow
        }
        set {
            lock.lock()
            unitFailedNow = newValue
            lock.unlock()
        }
    }

    func audioSessionDidBeginInterruption(_ session: LKRTCAudioSession) {
        lock.lock()
        interruptedNow = true
        lock.unlock()
        os_log("%{public}@", log: Self.log, type: .default, "Calls: WebRTC reports the audio session interrupted.")
    }

    func audioSessionDidEndInterruption(_ session: LKRTCAudioSession, shouldResumeSession: Bool) {
        lock.lock()
        interruptedNow = false
        lock.unlock()
    }

    func audioSession(_ audioSession: LKRTCAudioSession, audioUnitStartFailedWithError error: Error) {
        unitFailed = true
        os_log("%{public}@", log: Self.log, type: .error, "warning: Calls: WebRTC's audio unit would not start: \(RtcAudioGate.describe(error))")
    }
}
#endif
