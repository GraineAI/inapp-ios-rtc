import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/**
 * A REAL WEBRTC CALL WITH A REAL AGENT — opt-in, never in the default run:
 *
 *     GRAINE_LIVE_RTC=1 GRAINE_LIVE_RTC_KEY=<publishable key> swift test --filter RtcLiveTests
 *
 * The engine exactly as a phone runs it — the mint, the SIP user agent, the
 * control channel, libwebrtc (the Mac's slice) — against production. Nothing
 * plays out loud and no microphone is opened: the audio device renders by
 * itself, without hardware, and sends silence; what is measured is the
 * agent's greeting arriving (bytes, then level and energy). Each run is a
 * real call on the agent's workspace, kept under 20 seconds. The key comes
 * from the environment only.
 *
 * The second test forces the fallback: a mint that cannot succeed, and the
 * call carried on the voice socket instead, inside the same conversation.
 */
@Suite(.serialized) struct RtcLiveTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["GRAINE_LIVE_RTC"] == "1" }

    static func key() throws -> String {
        try #require(ProcessInfo.processInfo.environment["GRAINE_LIVE_RTC_KEY"].flatMap { $0.isEmpty ? nil : $0 }, "GRAINE_LIVE_RTC_KEY is not set")
    }

    static let base = "https://" + "www.graine.ai"

    @Test(.enabled(if: RtcLiveTests.enabled), .timeLimit(.minutes(1)))
    func aWebRtcCallAgainstProduction() async throws {
        let key = try Self.key()
        // No speaker, no microphone: the device module renders on its own thread.
        WebRTCMedia.factoryOptions = .init(audioEngine: true, manualRendering: true)
        let log = LiveRtcLog()
        let sockets = RecordingSocketFactory(log: log)
        let holder = MediaHolder()
        let variables = [("who_called", "customer"), ("call_reason", "sdk_rtc_live_test")]
        let identity = IdentityWire.Fields(value: nil, installId: "rtc-live-\(UUID().uuidString.lowercased())", memory: false, timezone: TimeZone.current.identifier, callId: nil)
        let request = GraineRtcRequest(
            baseUrl: Self.base,
            controlHost: "wss://" + "ws.graine.ai",
            mintBody: { id in RtcMintBody.json(publishableKey: key, sessionId: id, callVariables: variables, variables: variables, identity: identity) },
            sdkVersion: GraineVersion.name,
            budgetSeconds: 12,
            debug: true
        )
        let engine = RtcCallEngine(request: request, parts: RtcCallEngine.Parts(
            clock: DispatchRtcClock(),
            sockets: sockets,
            minting: URLSessionRtcMinting(),
            random: SystemSipRandom(),
            makeMedia: { clock in
                let media = WebRTCMedia(clock: clock)
                holder.media = media
                return media
            },
            audio: NoAudioControl()
        ))
        engine.onEvent = { log.event($0) }

        let began = Date()
        engine.prepare()
        engine.begin()
        // No CallKit on a Mac: the audio is the call's at once, so the INVITE leaves as soon as it is ready.
        engine.audioActivated()

        let connected = await eventually(15) { log.connected || log.unreachable != nil || log.refused != nil }
        for line in log.lines { print("[rtc-live] \(line)") }
        try #require(connected && log.connected, "not connected: \(String(describing: log.unreachable ?? log.refused))")
        let connectedAt = Date()
        print("[rtc-live] connected \(LiveRtcLog.ms(since: began)) ms after the start")

        // The greeting: bytes, then level and energy — within 10 s.
        var first: (packet: Int?, voice: Int?) = (nil, nil)
        var best = RtcInboundAudio(audioLevel: 0, totalAudioEnergy: 0, bytesReceived: 0, packetsReceived: 0, packetsLost: 0, jitter: 0, codec: nil)
        var peak = 0.0
        while Date().timeIntervalSince(connectedAt) < 10 {
            if let stats = await holder.inbound() {
                if stats.packetsReceived > 0, first.packet == nil { first.packet = LiveRtcLog.ms(since: connectedAt) }
                if stats.audioLevel > 0.01, first.voice == nil { first.voice = LiveRtcLog.ms(since: connectedAt) }
                peak = max(peak, stats.audioLevel)
                best = stats
            }
            // Enough heard (two seconds of the greeting) and the control channel joined: done.
            if let voice = first.voice, LiveRtcLog.ms(since: connectedAt) > voice + 2_000, log.controlReady { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        print("[rtc-live] inbound: \(best.packetsReceived) packets, \(best.bytesReceived) bytes, lost \(best.packetsLost), jitter \(best.jitter) s, codec \(best.codec ?? "?"), path \(best.path ?? "?"), rtt \(best.roundTrip.map { String(format: "%.3f s", $0) } ?? "?")")
        print("[rtc-live] level: peak \(String(format: "%.3f", peak)), energy \(String(format: "%.4f", best.totalAudioEnergy)); first packet +\(first.packet.map(String.init) ?? "-") ms, first voice +\(first.voice.map(String.init) ?? "-") ms after connected")
        print("[rtc-live] control_ready: \(log.controlReady); captions: \(log.captions.joined(separator: " | "))")

        engine.hangUp()
        _ = await eventually(3) { sockets.closedSip }
        let total = LiveRtcLog.ms(since: began)
        print("[rtc-live] SIP sent: \(sockets.sipSummary(sent: true))")
        print("[rtc-live] SIP received: \(sockets.sipSummary(sent: false))")
        print("[rtc-live] total \(total) ms; SIP socket closed: \(sockets.closedSip)")

        #expect(best.bytesReceived > 0, "the agent's audio arrived")
        #expect(peak > 0.01 && best.totalAudioEnergy > 0.001, "and it was the agent's voice, not silence (peak \(peak), energy \(best.totalAudioEnergy))")
        #expect(log.controlReady, "the control channel joined the call")
        #expect(sockets.received.contains { $0.hasPrefix("SIP/2.0 200") && $0.contains(" BYE\r\n") }, "the BYE was answered")
        #expect(sockets.sent.contains { $0.hasPrefix("REGISTER") && $0.contains("Expires: 0") }, "the registration withdrawn")
        #expect(total < 20_000, "under 20 s")
    }

    @Test(.enabled(if: RtcLiveTests.enabled), .timeLimit(.minutes(1)))
    func aMintThatFailsFallsBackToTheSocketInTheSameCall() async throws {
        let key = try Self.key()
        let graine = GraineInApp(config: GraineConfig(baseUrl: Self.base, publishableKey: key, appVersion: "ios-rtc-live"))
        let reports = LockedList<CallTransportReport>()
        let events = LockedList<CallEngine.Event>()
        let audio = CountingAudio()
        let variables = CallEngine.variables(sdk: [:], whoCalled: "customer", reason: "sdk_rtc_fallback_test", own: [:])
        let conversation = CallConversation(
            setup: CallEngine.Setup(
                publishableKey: key,
                baseUrl: graine.config.baseUrl,
                variables: variables,
                contextFrame: { nil },
                session: { done in graine.loadSession(done) },
                runAction: { _, _, answer in answer(.refused("not in this test")) },
                callVariables: variables,
                identity: graine.identityFields(callId: nil)
            ),
            audio: audio,
            network: URLSessionCallNetwork(),
            scheduler: DispatchCallScheduler(),
            transport: .webrtc,
            debug: true,
            // The real module, minting where nothing answers: the mint fails, the socket carries the call.
            rtcModule: { FallbackProbeModule() },
            takePrepared: { _ in nil },
            onTransport: { reports.add($0) },
            onEvent: { events.add($0) }
        )
        let began = Date()
        conversation.start()
        conversation.startAudio()
        let opened = await eventually(20) { events.items.contains { if case .opened = $0 { return true }; return false } }
        let heard = await eventually(8) { audio.samples > 0 }
        print("[rtc-live] fallback: \(reports.items), opened \(opened) after \(LiveRtcLog.ms(since: began)) ms, agent audio \(audio.samples) samples")
        conversation.hangUp()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(reports.items == [CallTransportReport(transport: .websocket, requested: .webrtc, reason: "mint_failed")])
        #expect(opened, "the voice socket carried the call")
        #expect(events.items.contains { if case .opened(let t) = $0 { return t == .gateway || t == .direct }; return false })
        #expect(heard, "and the agent spoke on it")
        #expect(LiveRtcLog.ms(since: began) < 20_000)
    }
}

// MARK: - What the live tests record

/// The real module, but its call session minted at a path nothing answers.
final class FallbackProbeModule: GraineRtcModule {
    var isSupported: Bool { true }
    func makeCall(_ request: GraineRtcRequest) -> GraineRtcCall {
        var broken = request
        broken.baseUrl = request.baseUrl + "/rtc-live-fallback-probe"
        return RtcCallEngine(request: broken, parts: .production())
    }
}

final class MediaHolder {
    private let lock = NSLock()
    private var held: WebRTCMedia?

    var media: WebRTCMedia? {
        get { lock.lock(); defer { lock.unlock() }; return held }
        set { lock.lock(); held = newValue; lock.unlock() }
    }

    func inbound() async -> RtcInboundAudio? {
        guard let media = media else { return nil }
        return await withCheckedContinuation { continuation in media.inboundAudio { continuation.resume(returning: $0) } }
    }
}

final class LockedList<T> {
    private let lock = NSLock()
    private var list: [T] = []
    func add(_ item: T) { lock.lock(); list.append(item); lock.unlock() }
    var items: [T] { lock.lock(); defer { lock.unlock() }; return list }
}

/// The voice socket's speaker, counted; its microphone, silent.
final class CountingAudio: CallAudioIO {
    private let lock = NSLock()
    private var count = 0
    var samples: Int { lock.lock(); defer { lock.unlock() }; return count }
    func startCapture(_ onFrame: @escaping (Data) -> Void) throws {}
    func play(_ pcm: [Int16], sampleRate: Int) { lock.lock(); count += pcm.count; lock.unlock() }
    func clear() {}
    func bufferedSeconds() -> Double { 0 }
    func stop() {}
}

final class LiveRtcLog {
    private let lock = NSLock()
    private var events: [GraineRtcEvent] = []
    private var logLines: [String] = []

    func event(_ event: GraineRtcEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        if case .log(let line) = event { logLines.append(line) }
    }

    var lines: [String] { lock.lock(); defer { lock.unlock() }; return logLines }
    var connected: Bool { has { if case .connected = $0 { return true }; return false } }
    var controlReady: Bool { lines.contains { $0.contains("control: joined") } }

    var unreachable: String? {
        lock.lock()
        defer { lock.unlock() }
        for event in events { if case let .unreachable(reason, detail) = event { return "\(reason.rawValue): \(detail)" } }
        return nil
    }

    var refused: String? {
        lock.lock()
        defer { lock.unlock() }
        for event in events { if case let .refused(code, message) = event { return "\(code): \(message)" } }
        return nil
    }

    var captions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event -> String? in
            guard case .control(let text) = event, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return nil }
            return "\(type)\((object["data"] as? String).map { ": \($0)" } ?? "")"
        }
    }

    private func has(_ test: (GraineRtcEvent) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains(where: test)
    }

    static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }
}

/// The real sockets, every SIP message they carried recorded (the control channel's too).
final class RecordingSocketFactory: RtcSocketFactory {
    private let inner = URLSessionRtcSocketFactory()
    private let lock = NSLock()
    private var sentTexts: [String] = []
    private var receivedTexts: [String] = []
    private var sipClosed = false
    private let log: LiveRtcLog

    init(log: LiveRtcLog) {
        self.log = log
    }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return sentTexts }
    var received: [String] { lock.lock(); defer { lock.unlock() }; return receivedTexts }
    var closedSip: Bool { lock.lock(); defer { lock.unlock() }; return sipClosed }

    func open(_ url: URL, protocols: [String], events: RtcSocketEvents) -> RtcSocket {
        let isSip = protocols == ["sip"]
        var recorded = events
        recorded.received = { [weak self] text in
            if isSip { self?.record(received: text) }
            events.received(text)
        }
        let socket = inner.open(url, protocols: protocols, events: recorded)
        return isSip ? RecordedSocket(socket, factory: self) : socket
    }

    fileprivate func record(sent text: String) { lock.lock(); sentTexts.append(text); lock.unlock() }
    fileprivate func record(received text: String) { lock.lock(); receivedTexts.append(text); lock.unlock() }
    fileprivate func recordClose() { lock.lock(); sipClosed = true; lock.unlock() }

    /// Each message as its first line (and CSeq): REGISTER, 401, REGISTER, 200, INVITE, 100, 401, ACK, …
    func sipSummary(sent: Bool) -> String {
        (sent ? self.sent : received).compactMap { text -> String? in
            guard let m = SipParser.parse(text) else { return nil }
            let head = m.method ?? "\(m.statusCode ?? 0)"
            return "\(head) [\(m.cseq.map { "\($0.number) \($0.method)" } ?? "")]"
        }.joined(separator: ", ")
    }
}

private final class RecordedSocket: RtcSocket {
    private let inner: RtcSocket
    private weak var factory: RecordingSocketFactory?

    init(_ inner: RtcSocket, factory: RecordingSocketFactory) {
        self.inner = inner
        self.factory = factory
    }

    func send(_ text: String) {
        factory?.record(sent: text)
        inner.send(text)
    }

    func close() {
        factory?.recordClose()
        inner.close()
    }
}
