import Foundation

/*
 * THE MEDIA PATH, KEPT — one answered dial's recovery inside WebRTC, the voice
 * bar's MediaRecovery (lib/rtc-media-recovery.ts) on the engine's clock. The
 * rules are RtcResilience's; this holds their timers.
 *
 *   setup  answered, the path not up yet: waited for until its deadline
 *          (8 s × the link's pace), longer while it is still making progress;
 *          then an ICE restart — a new offer with new ICE credentials, in the
 *          same call — and a second only when something changed that a new
 *          gathering can use; then `mediaFailed(.iceTimeout)`: the engine hands
 *          the call to the WebSocket. With nothing in flight at all, the first
 *          restart comes early (2.5 s × pace); the hand-over never comes before
 *          the deadline all the same
 *   up     the path carries audio
 *   lost   the path went away after it was up: reconnecting, a restart 3 s in
 *          (at once when ICE says failed), never into no network — time offline
 *          is waited out, not counted, and the network's return gets 2 s to heal
 *          by itself first; a refused restart ends restarts, not the call;
 *          given up (dropped) after 15 s × pace with a network, never inside an
 *          open restart's window, or after 30 s without one
 *
 * It never ends a call and never dials: a restart happens inside the call that
 * is already answered — no new conversation, no second greeting. `dispose()`
 * (a hang-up, the end) silences every timer, and a handler for an older
 * restart or a disposed dial does nothing. Everything runs on the clock.
 */

/// Why the media path is given up on: before it ever came up, or lost after it was.
enum RtcMediaFailure: Equatable {
    case iceTimeout(String)
    case iceFailed(String)
    case iceDisconnected(String)

    var detail: String {
        switch self {
        case .iceTimeout(let d), .iceFailed(let d), .iceDisconnected(let d): return d
        }
    }
}

/// One restart's outcome, as the engine reports it.
struct RtcRestartHandlers {
    /// The restart's offer is made, carrying this many candidates. None: it cannot make a path.
    var offer: (Int) -> Void
    /// Its answer arrived and was applied.
    var answered: () -> Void
    /// Refused, unanswered, or its answer could not be applied: no more restarts on this dial.
    var refused: (String) -> Void
}

/// What the recovery asks of the call it keeps.
protocol RtcRecoveryHost: AnyObject {
    func recoveryPace() -> Double
    func recoveryOnline() -> Bool
    /// A new offer can be sent now: the call is established, no other offer is out, its socket is up.
    func recoveryCanReoffer() -> Bool
    /// Send ICE restart `n`, gathering only the relays over TCP and TLS when `relayOnly`. False when it could not be sent.
    func recoveryRestart(_ n: Int, relayOnly: Bool, _ handlers: RtcRestartHandlers) -> Bool
    /// The connection's checks, for the rules; nil when they cannot be read.
    func recoveryStats(_ done: @escaping (RtcIceReading?) -> Void)
    /// The gathering says UDP is blocked, and there are relays over TCP or TLS to use instead.
    func recoveryUdpBlocked() -> Bool
    /// This dial's path is gone for good. Said once.
    func recoveryFailed(_ failure: RtcMediaFailure)
    /// An answered call that had its audio is reconnecting — or is not any more.
    func recoveryReconnecting(_ active: Bool)
    /// The path came up after `restarts` restarts, `seconds` after it was lost (or after the answer).
    func recoveryRecovered(restarts: Int, seconds: Double)
    func recoveryLog(_ line: String)
}

final class RtcMediaRecovery {
    enum Phase: Equatable { case idle, setup, up, lost, done }

    private weak var host: RtcRecoveryHost?
    private let clock: RtcClock
    private(set) var phase = Phase.idle
    private var timers: [String: RtcTimer] = [:]
    /// Restarts made for the current trouble (a setup, or one loss).
    private(set) var restarts = 0
    /// A restart's offer is out and not yet answered or refused.
    private(set) var inFlight = false
    /// The far side refused a restart: none is tried again on this dial.
    private(set) var refused = false
    private var relayOnlyTried = false
    private var netEpoch = 0
    private var epochAtRestart = 0
    private var lostFailed = false
    private var troubleAt = 0.0
    /// A setup is never handed over before this: its deadline from the answer, early restart or not.
    private var notBefore = 0.0
    private var window = (deadline: 0.0, hardCap: 0.0, extended: 0.0)
    private var baseline: RtcIceReading?
    private var lastReading: RtcIceReading?

    init(host: RtcRecoveryHost, clock: RtcClock) {
        self.host = host
        self.clock = clock
    }

    /// The dial was answered: the setup's clock starts.
    func answered() {
        guard phase == .idle, let host = host else { return }
        phase = .setup
        troubleAt = clock.now
        let pace = host.recoveryPace()
        notBefore = clock.now + RtcResilience.mediaDeadline(pace: pace)
        openWindow(deadline: RtcResilience.mediaDeadline(pace: pace), hardCap: RtcResilience.mediaHardCap(pace: pace))
        arm("early", RtcResilience.earlyRestart(pace: pace)) { [weak self] in self?.earlyLook() }
    }

    /// The path carries audio.
    func pathUp() {
        guard phase == .setup || phase == .lost else { return }
        let was = phase
        phase = .up
        clearAll()
        if was == .lost { host?.recoveryReconnecting(false) }
        if restarts > 0 { host?.recoveryRecovered(restarts: restarts, seconds: clock.now - troubleAt) }
        // The next trouble starts its own count; a refusal stays (the far side would refuse again).
        restarts = 0
        relayOnlyTried = false
        inFlight = false
    }

    /// ICE went disconnected (`failed` false) or failed. Before the path was up, failed is acted on at once; after, it is a loss.
    func pathLost(failed: Bool) {
        guard let host = host else { return }
        switch phase {
        case .setup:
            guard failed, !inFlight else { return }
            clear("deadline")
            clear("look")
            act("ICE failed before the path came up", known: nil)
        case .lost:
            // A disconnection that became a failure: ICE has given up, so the restart need not wait.
            if failed && !lostFailed {
                lostFailed = true
                if host.recoveryOnline() && !inFlight { clear("restartAt"); lostRestart() }
            }
        case .up:
            phase = .lost
            lostFailed = failed
            troubleAt = clock.now
            restarts = 0
            relayOnlyTried = false
            host.recoveryReconnecting(true)
            if host.recoveryOnline() {
                armLostClock(restartIn: failed ? 0 : RtcResilience.restartAfter)
            } else {
                arm("offlineHold", RtcResilience.offlineHold) { [weak self] in self?.giveUp("the network did not come back") }
            }
        default:
            break
        }
    }

    /// The network changed: gone (false), back or another one (true).
    func networkChanged(online: Bool) {
        netEpoch += 1
        guard phase == .lost else { return }
        if !online {
            // Nothing is restarted into no network, and the time offline is not held against the path.
            clear("restartAt")
            clear("giveUp")
            clear("restartWindow")
            if timers["offlineHold"] == nil { arm("offlineHold", RtcResilience.offlineHold) { [weak self] in self?.giveUp("the network did not come back") } }
            return
        }
        clear("offlineHold")
        armLostClock(restartIn: RtcResilience.onlineSettle)
    }

    /// The dial is over: every timer goes, and nothing fires again. A reconnect in progress is said over, once.
    func dispose() {
        let wasLost = phase == .lost
        phase = .done
        clearAll()
        if wasLost { host?.recoveryReconnecting(false) }
    }

    /// The setup is still being worked on — a restart out, a restart's window open, or progress carrying it past its deadline.
    var holdsTheSetup: Bool { phase == .setup }

    // MARK: - setup

    private func openWindow(deadline: Double, hardCap: Double) {
        window = (deadline, hardCap, 0)
        baseline = nil
        if deadline > RtcResilience.progressLook {
            arm("look", deadline - RtcResilience.progressLook) { [weak self] in
                self?.read { reading in self?.baseline = reading }
            }
        }
        arm("deadline", deadline) { [weak self] in self?.judge() }
    }

    private func earlyLook() {
        guard phase == .setup, restarts == 0, !inFlight else { return }
        read { [weak self] reading in
            guard let self = self, let host = self.host, self.phase == .setup, self.restarts == 0, !self.inFlight else { return }
            guard RtcResilience.nothingInFlight(reading) else { return }
            guard host.recoveryOnline(), host.recoveryCanReoffer() else { return }   // the deadline's look tries again
            _ = self.sendRestart(udpBlocked: host.recoveryUdpBlocked(), why: "nothing to check \(self.ms(self.clock.now - self.troubleAt)) ms after the answer")
        }
    }

    /// The setup's deadline (or a look past it): wait on while it is progressing, else act.
    private func judge() {
        guard phase == .setup else { return }
        read { [weak self] reading in
            guard let self = self, self.phase == .setup else { return }
            let progressing = RtcResilience.progressed(from: self.baseline, to: reading)
            self.baseline = reading
            let w = self.window
            let step = RtcResilience.setupStep(pathUp: false, progressing: progressing, elapsed: w.deadline + w.extended, deadline: w.deadline, hardCap: w.hardCap)
            if step == .wait {
                if w.extended == 0 { self.host?.recoveryLog("media: no path \(self.ms(w.deadline)) ms in, still making progress — waiting (at most \(self.ms(w.hardCap)) ms)") }
                self.window.extended += RtcResilience.progressLook
                self.arm("deadline", RtcResilience.progressLook) { [weak self] in self?.judge() }
                return
            }
            let why = self.restarts > 0
                ? "no path \(self.ms(w.deadline + w.extended)) ms after restart \(self.restarts)"
                : "no path \(self.ms(w.deadline + w.extended)) ms after the answer"
            self.act(why, known: reading)
        }
    }

    /// No path and not moving: restart if that may help, else give it up — never before the deadline.
    private func act(_ why: String, known: RtcIceReading?) {
        guard phase == .setup, let host = host else { return }
        let udpBlocked = host.recoveryUdpBlocked()
        let permitted = !inFlight && RtcResilience.restartPermitted(
            restarts: restarts, networkChanged: netEpoch != epochAtRestart, udpBlocked: udpBlocked, relayOnlyTried: relayOnlyTried, refused: refused
        )
        if permitted {
            if host.recoveryOnline() && host.recoveryCanReoffer() {
                if sendRestart(udpBlocked: udpBlocked, why: why) { return }
            } else if window.deadline + window.extended < window.hardCap - 1e-9 {
                // Not now — no network, or the call's socket reconnecting: tried again shortly, inside the hard cap.
                window.extended += RtcResilience.restartRetry
                arm("deadline", RtcResilience.restartRetry) { [weak self] in self?.act(why, known: nil) }
                return
            }
        }
        // Never handed over before the deadline: an early restart that failed waits it out (and may restart again then).
        let wait = notBefore - clock.now
        if wait > 1e-9 {
            arm("deadline", wait) { [weak self] in self?.act(why, known: nil) }
            return
        }
        giveUp(why, failure: .iceTimeout(why))
    }

    // MARK: - lost

    private func armLostClock(restartIn: Double) {
        guard let host = host else { return }
        arm("giveUp", RtcResilience.lostGiveUp(pace: host.recoveryPace())) { [weak self] in self?.lostGiveUp() }
        guard !inFlight else { return }
        // At once means at once (ICE failed): no timer between the failure and its restart.
        if restartIn <= 0 { clear("restartAt"); lostRestart() } else { arm("restartAt", restartIn) { [weak self] in self?.lostRestart() } }
    }

    /// The lost path's time is up — unless a restart's window is still open: that path may yet come up, and its window is bounded.
    private func lostGiveUp() {
        if timers["restartWindow"] != nil {
            arm("giveUp", RtcResilience.restartRetry) { [weak self] in self?.lostGiveUp() }
            return
        }
        giveUp("the media path did not come back")
    }

    private func lostRestart() {
        guard phase == .lost, !inFlight, let host = host, host.recoveryOnline() else { return }   // the network's return arms the next look
        let udpBlocked = host.recoveryUdpBlocked()
        let permitted = RtcResilience.restartPermitted(
            restarts: restarts, networkChanged: netEpoch != epochAtRestart, udpBlocked: udpBlocked, relayOnlyTried: relayOnlyTried, refused: refused
        )
        guard permitted else { return }   // the give-up decides
        guard host.recoveryCanReoffer() else {
            arm("restartAt", RtcResilience.restartRetry) { [weak self] in self?.lostRestart() }
            return
        }
        _ = sendRestart(udpBlocked: udpBlocked, why: lostFailed ? "ICE failed" : "the path was lost \(ms(clock.now - troubleAt)) ms ago")
    }

    // MARK: - a restart

    @discardableResult
    private func sendRestart(udpBlocked: Bool, why: String) -> Bool {
        guard let host = host else { return false }
        let n = restarts + 1
        let relayOnly = udpBlocked && !relayOnlyTried
        restarts = n
        inFlight = true
        epochAtRestart = netEpoch
        if relayOnly { relayOnlyTried = true }
        host.recoveryLog("media: ICE restart \(n) — \(why)\(relayOnly ? " (the relays over TCP and TLS only: UDP looks blocked)" : "")")
        let stale: () -> Bool = { [weak self] in
            guard let self = self else { return true }
            return self.restarts != n || (self.phase != .setup && self.phase != .lost)
        }
        // Set once this restart has been judged hopeless (refused, or an offer with nothing in it) — which an engine
        // answering at once does before recoveryRestart even returns: then no window is opened over the next step.
        var settled = false
        let sent = host.recoveryRestart(n, relayOnly: relayOnly, RtcRestartHandlers(
            offer: { [weak self] candidates in
                guard let self = self, !stale(), candidates == 0, !settled else { return }
                settled = true
                // An offer with no candidate cannot make a path: the next step now, not at the window's end.
                self.host?.recoveryLog("media: ICE restart \(n) gathered nothing")
                self.over(n)
            },
            answered: { [weak self] in
                guard let self = self, !stale() else { return }
                self.inFlight = false
                self.host?.recoveryLog("media: ICE restart \(n) answered")
            },
            refused: { [weak self] detail in
                guard let self = self, !stale() else { return }
                self.inFlight = false
                self.refused = true
                self.host?.recoveryLog("media: ICE restart \(n) refused (\(detail)) — no more on this call")
                guard !settled else { return }
                settled = true
                self.over(n)
            }
        ))
        guard sent else {
            restarts = n - 1
            inFlight = false
            if relayOnly { relayOnlyTried = false }
            return false
        }
        guard !settled, phase == .setup || phase == .lost, restarts == n else { return true }
        let pace = host.recoveryPace()
        if phase == .setup {
            openWindow(deadline: RtcResilience.restartWindow(pace: pace), hardCap: RtcResilience.restartHardCap(pace: pace))
        } else {
            arm("restartWindow", RtcResilience.restartWindow(pace: pace)) { [weak self] in self?.over(n) }
        }
        return true
    }

    /// Restart `n` will not bring the path back (refused, nothing gathered, or its window ran out).
    private func over(_ n: Int) {
        guard restarts == n else { return }
        if phase == .setup {
            clear("deadline")
            clear("look")
            act("restart \(n) did not bring the path up", known: nil)
        } else if phase == .lost {
            clear("restartWindow")
            if !refused { inFlight = false }
            lostRestart()
        }
    }

    private func giveUp(_ why: String, failure: RtcMediaFailure? = nil) {
        guard phase == .setup || phase == .lost else { return }
        let wasLost = phase == .lost
        let reason = failure ?? (lostFailed ? .iceFailed(why) : .iceDisconnected(why))
        phase = .done
        clearAll()
        host?.recoveryLog("media: \(why) — \(restarts > 0 ? "after \(restarts) ICE restart\(restarts > 1 ? "s" : ""), " : "")the path is given up")
        if wasLost { host?.recoveryReconnecting(false) }
        host?.recoveryFailed(reason)
    }

    // MARK: - plumbing

    private func read(_ done: @escaping (RtcIceReading?) -> Void) {
        guard let host = host else { return done(nil) }
        host.recoveryStats { [weak self] reading in
            if let reading = reading { self?.lastReading = reading }
            done(reading)
        }
    }

    private func arm(_ name: String, _ seconds: Double, _ block: @escaping () -> Void) {
        clear(name)
        timers[name] = clock.after(max(0, seconds)) { [weak self] in
            guard let self = self else { return }
            self.timers[name] = nil
            guard self.phase != .done else { return }
            block()
        }
    }

    private func clear(_ name: String) {
        timers[name]?.cancel()
        timers[name] = nil
    }

    private func clearAll() {
        for timer in timers.values { timer.cancel() }
        timers = [:]
    }

    private func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
}
