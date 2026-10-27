import Foundation
import Network

/*
 * THE PHONE'S NETWORK, AS A CALL NEEDS TO KNOW IT (RtcMediaRecovery): whether
 * there is one — nothing is restarted or redialled into no network, and time
 * offline is not held against a lost path — and a word when it changes: gone,
 * back, or another one (Wi-Fi to mobile data), which is what earns a second
 * ICE restart and makes the last network's word on UDP worthless.
 */
protocol RtcNetwork: AnyObject {
    var online: Bool { get }
    /// Hear every change, on any thread, with the new online state. Returns what stops it.
    func watch(_ changed: @escaping (Bool) -> Void) -> () -> Void
}

/// The Mac's and the tests' default: online, and it never changes.
final class SteadyRtcNetwork: RtcNetwork {
    var online: Bool { true }
    func watch(_ changed: @escaping (Bool) -> Void) -> () -> Void { {} }
}

/**
 * The phone's own, from NWPathMonitor: online while the path is satisfied; a
 * change is the path's status or the kinds of interface it uses. No
 * permission is needed, and nothing about the network leaves the phone.
 */
final class PathRtcNetwork: RtcNetwork {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.graine.rtc.network")
    private let lock = NSLock()
    private var current = true
    private var lastKey: String?
    private var watchers: [UUID: (Bool) -> Void] = [:]

    init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    var online: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func watch(_ changed: @escaping (Bool) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        watchers[id] = changed
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.watchers[id] = nil
            self?.lock.unlock()
        }
    }

    private func update(_ path: NWPath) {
        let online = path.status == .satisfied
        let kinds: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
        let key = "\(online)|" + kinds.filter { path.usesInterfaceType($0) }.map { "\($0)" }.joined(separator: ",")
        lock.lock()
        let first = lastKey == nil
        let changed = key != lastKey
        lastKey = key
        current = online
        let targets = Array(watchers.values)
        lock.unlock()
        // The first reading is where the call starts, not a change.
        guard changed, !first else { return }
        for target in targets { target(online) }
    }
}
