import Foundation

/*
 * THE CALL'S CONTROL CHANNEL — `{wsHost}/control/v1/{sessionId}`.
 *
 * WebRTC carries the audio and nothing else. The screen the customer is on,
 * the agent's actions, its captions and its components travel here instead,
 * as the same frames the voice socket carries; the server joins this socket to
 * the call by the session id the INVITE named.
 *
 *   until the call exists   the server holds the handshake (an id it never
 *                           learns is closed 4404 after 20 s); frames wait in
 *                           a queue of 32, oldest dropped, the newest screen
 *                           replacing the last
 *   control_ready           joined: the queue goes, and a ping every 25 s keeps
 *                           a load balancer from calling an idle socket dead
 *   closed under the call   opened again 2 s later — a blind agent for a turn,
 *                           not for the rest of the call
 *
 * The SIP BYE ends a call, never this socket; the engine closes it itself.
 */
final class RtcControlChannel {
    static let queueLimit = 32
    static let pingSeconds = 25.0
    static let reopenSeconds = 2.0

    private let url: URL
    private let clock: RtcClock
    private let sockets: RtcSocketFactory
    private let log: (String) -> Void
    /// A frame for the call's own handling (captions, actions, components), as received.
    var onFrame: (String) -> Void = { _ in }
    /// Joined (true) or lost (false).
    var onJoined: (Bool) -> Void = { _ in }

    private var socket: RtcSocket?
    private(set) var joined = false
    private var closedByUs = false
    private var queue: [(kind: String?, text: String)] = []
    private var pingTimer: RtcTimer?
    private var reopenTimer: RtcTimer?
    /// How many times it has been opened — for the tests and the log.
    private(set) var opens = 0

    init(host: String, sessionId: String, clock: RtcClock, sockets: RtcSocketFactory, log: @escaping (String) -> Void = { _ in }) {
        var base = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let id = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        self.url = URL(string: base + "/control/v1/" + id) ?? URL(string: "wss://ws.graine.ai/control/v1/" + id)!
        self.clock = clock
        self.sockets = sockets
        self.log = log
    }

    var address: URL { url }

    /// Open it (again). Safe to call twice.
    func open() {
        guard socket == nil, !closedByUs else { return }
        opens += 1
        let events = RtcSocketEvents(
            opened: {},
            received: { [weak self] text in self?.clock.run { self?.received(text) } },
            closed: { [weak self] code, detail in self?.clock.run { self?.socketClosed(code: code, detail: detail) } }
        )
        socket = sockets.open(url, protocols: [], events: events)
    }

    /// Send now when joined; otherwise queue it. A frame of the same `kind` already queued is replaced (the screen).
    func send(_ text: String, kind: String? = nil) {
        guard !closedByUs else { return }
        if joined, let socket = socket {
            socket.send(text)
            return
        }
        if let kind = kind { queue.removeAll { $0.kind == kind } }
        queue.append((kind, text))
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
    }

    /// For good: nothing reopens it.
    func close() {
        guard !closedByUs else { return }
        closedByUs = true
        joined = false
        pingTimer?.cancel()
        reopenTimer?.cancel()
        queue = []
        socket?.close()
        socket = nil
    }

    var queued: [String] { queue.map { $0.text } }

    private func received(_ text: String) {
        guard !closedByUs else { return }
        let type = Self.type(of: text)
        if type == "pong" { return }
        if type == "control_ready" {
            joined = true
            schedulePing()
            let waiting = queue
            queue = []
            for frame in waiting { socket?.send(frame.text) }
            onJoined(true)
            return
        }
        onFrame(text)
    }

    private func schedulePing() {
        pingTimer?.cancel()
        pingTimer = clock.after(Self.pingSeconds) { [weak self] in
            guard let self = self, self.joined, !self.closedByUs else { return }
            self.socket?.send(#"{"type":"ping"}"#)
            self.schedulePing()
        }
    }

    private func socketClosed(code: Int?, detail: String) {
        socket = nil
        pingTimer?.cancel()
        let wasJoined = joined
        joined = false
        if wasJoined { onJoined(false) }
        guard !closedByUs else { return }
        log("control: closed (\(code.map(String.init) ?? detail)); opening again in \(Int(Self.reopenSeconds)) s")
        reopenTimer?.cancel()
        reopenTimer = clock.after(Self.reopenSeconds) { [weak self] in self?.open() }
    }

    /// A frame's `type`, read without trusting it.
    static func type(of text: String) -> String? {
        guard text.utf8.count <= 1_048_576, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["type"] as? String
    }
}
