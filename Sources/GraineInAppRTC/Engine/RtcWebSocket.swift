import Foundation

/*
 * THE CALL'S TWO WEBSOCKETS: SIP to the SBC (subprotocol "sip", RFC 7118) and
 * the control channel to Graine (no subprotocol). URLSessionWebSocketTask,
 * which answers the server's pings by itself. No Origin header is sent, as for
 * every in-app request.
 */

protocol RtcSocket: AnyObject {
    func send(_ text: String)
    /// Close with 1000. No `closed` event follows a close the engine asked for.
    func close()
}

struct RtcSocketEvents {
    var opened: () -> Void
    var received: (String) -> Void
    /// The socket is gone (`code` when the far side closed it), exactly once, unless we closed it.
    var closed: (_ code: Int?, _ detail: String) -> Void
}

protocol RtcSocketFactory: AnyObject {
    func open(_ url: URL, protocols: [String], events: RtcSocketEvents) -> RtcSocket
}

final class URLSessionRtcSocketFactory: RtcSocketFactory {
    func open(_ url: URL, protocols: [String], events: RtcSocketEvents) -> RtcSocket {
        URLSessionRtcSocket(url: url, protocols: protocols, events: events)
    }
}

final class URLSessionRtcSocket: NSObject, RtcSocket, URLSessionWebSocketDelegate {
    private let events: RtcSocketEvents
    private let lock = NSLock()
    private var finished = false
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    init(url: URL, protocols: [String], events: RtcSocketEvents) {
        self.events = events
        super.init()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ai.graine.calls.rtc.socket"
        let configuration = URLSessionConfiguration.ephemeral
        // The control channel's handshake is held by the server until the call exists: never cut it short.
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        task = protocols.isEmpty ? session.webSocketTask(with: url) : session.webSocketTask(with: url, protocols: protocols)
        task.maximumMessageSize = 256 * 1024
        task.resume()
        receive()
    }

    func send(_ text: String) {
        guard !isFinished else { return }
        task.send(.string(text)) { [weak self] error in
            if let error = error { self?.finish(code: nil, detail: error.localizedDescription) }
        }
    }

    func close() {
        guard markFinished() else { return }
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.deliver(text)
                case .data(let data): if let text = String(data: data, encoding: .utf8) { self.deliver(text) }
                @unknown default: break
                }
                self.receive()
            case .failure(let error):
                self.finish(code: nil, detail: error.localizedDescription)
            }
        }
    }

    private func deliver(_ text: String) {
        guard !isFinished else { return }
        events.received(text)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard !isFinished else { return }
        events.opened()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let why = reason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        finish(code: closeCode.rawValue, detail: why ?? "closed (\(closeCode.rawValue))")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if let status = status, status >= 400 {
            finish(code: nil, detail: "refused (\(status))")
        } else {
            finish(code: nil, detail: error?.localizedDescription ?? "closed")
        }
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }

    private func finish(code: Int?, detail: String) {
        guard markFinished() else { return }
        task.cancel()
        session.finishTasksAndInvalidate()
        events.closed(code, detail)
    }
}
