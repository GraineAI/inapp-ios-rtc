import Foundation

/*
 * ONE SERIAL CONTEXT AND A CLOCK, FOR EVERYTHING A WEBRTC CALL DOES.
 *
 * The SIP user agent, the control channel and the engine all run on one
 * queue, so none of them needs a lock; the network and WebRTC's own threads
 * hop onto it. Tests hand in a clock they move by hand.
 */

protocol RtcTimer {
    func cancel()
}

extension DispatchWorkItem: RtcTimer {}

protocol RtcClock: AnyObject {
    /// Seconds on a clock that never jumps.
    var now: Double { get }
    /// Run on the context, after the current work.
    func run(_ block: @escaping () -> Void)
    /// Run on the context after `seconds`.
    @discardableResult
    func after(_ seconds: Double, _ block: @escaping () -> Void) -> RtcTimer
}

final class DispatchRtcClock: RtcClock {
    let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "ai.graine.calls.rtc", qos: .userInitiated)) {
        self.queue = queue
    }

    var now: Double { ProcessInfo.processInfo.systemUptime }

    func run(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    @discardableResult
    func after(_ seconds: Double, _ block: @escaping () -> Void) -> RtcTimer {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
        return item
    }
}

/// The random parts of SIP, in JsSIP's alphabets — handed in so tests can write golden messages.
protocol SipRandom: AnyObject {
    /// JsSIP's createRandomToken: `count` characters of base 32 (0-9, a-v).
    func token(_ count: Int) -> String
    /// A transaction's branch: `z9hG4bK` and a number below ten million.
    func branch() -> String
    /// The first CSeq of a call: a number below ten thousand.
    func initialCSeq() -> Int
    /// A lower-case UUID for `+sip.instance`.
    func uuid() -> String
    /// The control channel's session id: 16 random bytes as 32 lower-case hex.
    func sessionId() -> String
}

final class SystemSipRandom: SipRandom {
    private var generator = SystemRandomNumberGenerator()
    private let alphabet = Array("0123456789abcdefghijklmnopqrstuv")

    func token(_ count: Int) -> String {
        String((0..<count).map { _ in alphabet[Int.random(in: 0..<32, using: &generator)] })
    }

    func branch() -> String {
        "z9hG4bK\(Int.random(in: 0..<10_000_000, using: &generator))"
    }

    func initialCSeq() -> Int {
        Int.random(in: 0..<10_000, using: &generator)
    }

    func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    func sessionId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
