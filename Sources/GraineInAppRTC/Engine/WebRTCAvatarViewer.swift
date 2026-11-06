@_spi(GraineRTC) import GraineInApp
import AVFoundation
import Foundation
import LiveKitWebRTC
#if os(iOS)
import UIKit
#endif

/*
 * THE AGENT'S FACE, PLAYED NATIVELY — a second peer connection beside the
 * call's, made from the same factory (its audio device belongs to the whole
 * app), so the face's sound plays through the call's own audio: CallKit's
 * session, its route, its echo canceller.
 *
 *   receive only    one audio and one video transceiver, nothing sent; one data
 *                   channel for the service's clock
 *   the offer       complete before it leaves: the service never trickles
 *   the picture     an RTCMTLVideoView (aspect fill), and a counter of frames for
 *                   the stall rule
 *   the sound       the face's track volume: 0 until the core says it carries
 *                   the voice. Its level is measured before that volume, so the
 *                   hand-over can tell a quiet face from a silenced one
 *
 * WebRTC only: there is no other road for the face. The core
 * (GraineInApp Core/AvatarFace.swift) runs the requests, the clock and the
 * hand-over; this only moves media. Callbacks arrive on WebRTC's threads and
 * are handed on as they come; the core hops onto its own.
 */
final class WebRTCAvatarViewer: NSObject, GraineAvatarViewer, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    var onEvent: ((GraineAvatarViewerEvent) -> Void)?

    private let lock = NSLock()
    private var peer: LKRTCPeerConnection?
    private var channel: LKRTCDataChannel?
    private var audioTrack: LKRTCAudioTrack?
    private var videoTrack: LKRTCVideoTrack?
    private let frames = FrameCounter()
    private let meter = AudioLevelMeter()
    private var audible = false
    private var gathered: ((String?, String?) -> Void)?
    private var gatherTimer: DispatchWorkItem?
    private var closed = false
    #if os(iOS)
    private var view: LKRTCMTLVideoView?
    #endif

    // MARK: - GraineAvatarViewer

    func offer(iceServers: [GraineAvatarIceServer], gatherSeconds: Double, done: @escaping (String?, String?) -> Void) {
        let factory = WebRTCMedia.factory()
        let config = LKRTCConfiguration()
        config.iceServers = iceServers.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        // As the browser offers it: balanced bundle, RTCP multiplexed.
        config.bundlePolicy = .balanced
        config.rtcpMuxPolicy = .require
        let none = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: none, delegate: self) else {
            done(nil, "the peer connection could not be made")
            return
        }
        lock.lock()
        self.peer = peer
        lock.unlock()
        let receiveOnly = LKRTCRtpTransceiverInit()
        receiveOnly.direction = .recvOnly
        guard let audio = peer.addTransceiver(of: .audio, init: receiveOnly),
              let video = peer.addTransceiver(of: .video, init: receiveOnly) else {
            done(nil, "the transceivers could not be added")
            return
        }
        attach(audio: audio.receiver.track as? LKRTCAudioTrack, video: video.receiver.track as? LKRTCVideoTrack)
        let channelConfig = LKRTCDataChannelConfiguration()
        channelConfig.isOrdered = true
        if let channel = peer.dataChannel(forLabel: "playback", configuration: channelConfig) {
            channel.delegate = self
            lock.lock()
            self.channel = channel
            lock.unlock()
        }
        peer.offer(for: none) { [weak self] sdp, error in
            guard let self = self, let sdp = sdp else {
                done(nil, "no offer: \(error?.localizedDescription ?? "unknown")")
                return
            }
            peer.setLocalDescription(sdp) { error in
                if let error = error {
                    done(nil, "the offer was refused: \(error.localizedDescription)")
                    return
                }
                self.waitForCandidates(peer, seconds: gatherSeconds, done: done)
            }
        }
    }

    func applyAnswer(_ sdp: String, done: @escaping (String?) -> Void) {
        guard let peer = currentPeer() else {
            done("no peer connection")
            return
        }
        peer.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: sdp)) { error in
            done(error.map { "the answer was refused: \($0.localizedDescription)" })
        }
    }

    func send(_ text: String) {
        lock.lock()
        let channel = self.channel
        lock.unlock()
        guard let channel = channel, channel.readyState == .open else { return }
        _ = channel.sendData(LKRTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    func setAudible(_ audible: Bool) {
        lock.lock()
        self.audible = audible
        let track = audioTrack
        lock.unlock()
        track?.source.volume = audible ? 1 : 0
    }

    func sample(_ done: @escaping (Double?, Double?, Double?, Double?) -> Void) {
        guard let peer = currentPeer() else {
            done(nil, nil, nil, nil)
            return
        }
        let count = frames.count
        let face = meter.peakLevel()
        peer.statistics { report in
            var delay: Double?
            var emitted: Double?
            var decoded: Double?
            for stat in report.statistics.values where stat.type == "inbound-rtp" {
                let kind = stat.values["kind"] as? String ?? stat.values["mediaType"] as? String
                if kind == "audio" {
                    delay = (stat.values["jitterBufferDelay"] as? NSNumber)?.doubleValue
                    emitted = (stat.values["jitterBufferEmittedCount"] as? NSNumber)?.doubleValue
                } else if kind == "video" {
                    decoded = (stat.values["framesDecoded"] as? NSNumber)?.doubleValue
                }
            }
            // Frames drawn, else decoded: whichever this build reports.
            done(count > 0 ? Double(count) : decoded, face, delay, emitted)
        }
    }

    var videoView: AnyObject? {
        #if os(iOS)
        let make: () -> AnyObject? = { [weak self] in
            guard let self = self else { return nil }
            if let made = self.view { return made }
            let made = LKRTCMTLVideoView(frame: .zero)
            made.videoContentMode = .scaleAspectFill
            made.backgroundColor = .clear
            self.view = made
            self.lock.lock()
            let track = self.videoTrack
            self.lock.unlock()
            track?.add(made)
            return made
        }
        return Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)
        #else
        return nil
        #endif
    }

    func close() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let peer = self.peer
        let channel = self.channel
        let audio = audioTrack
        let video = videoTrack
        self.peer = nil
        self.channel = nil
        audioTrack = nil
        videoTrack = nil
        gatherTimer?.cancel()
        gatherTimer = nil
        gathered = nil
        lock.unlock()
        onEvent = nil
        audio?.source.volume = 0
        audio?.remove(meter)
        video?.remove(frames)
        #if os(iOS)
        let view = self.view
        self.view = nil
        if let view = view {
            DispatchQueue.main.async {
                video?.remove(view)
                view.removeFromSuperview()
            }
        }
        #endif
        channel?.delegate = nil
        channel?.close()
        peer?.close()
    }

    // MARK: - Tracks, candidates

    private func attach(audio: LKRTCAudioTrack?, video: LKRTCVideoTrack?) {
        lock.lock()
        audioTrack = audio
        videoTrack = video
        let heard = audible
        lock.unlock()
        // Silent until the core hands it the voice; measured all the same.
        audio?.source.volume = heard ? 1 : 0
        audio?.add(meter)
        video?.add(frames)
    }

    private func currentPeer() -> LKRTCPeerConnection? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : peer
    }

    /// The offer once gathering is complete — or what there is after `seconds`.
    private func waitForCandidates(_ peer: LKRTCPeerConnection, seconds: Double, done: @escaping (String?, String?) -> Void) {
        lock.lock()
        if peer.iceGatheringState == .complete {
            lock.unlock()
            done(peer.localDescription?.sdp, peer.localDescription == nil ? "no offer" : nil)
            return
        }
        gathered = done
        let timer = DispatchWorkItem { [weak self] in self?.finishGathering() }
        gatherTimer = timer
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    private func finishGathering() {
        lock.lock()
        let done = gathered
        gathered = nil
        gatherTimer?.cancel()
        gatherTimer = nil
        let sdp = closed ? nil : peer?.localDescription?.sdp
        lock.unlock()
        done?(sdp, sdp == nil ? "no offer" : nil)
    }

    // MARK: - LKRTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        if newState == .complete { finishGathering() }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        let word: String
        switch newState {
        case .new: word = "new"
        case .connecting: word = "connecting"
        case .connected: word = "connected"
        case .disconnected: word = "disconnected"
        case .failed: word = "failed"
        case .closed: word = "closed"
        @unknown default: return
        }
        onEvent?(.connection(word))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    // MARK: - LKRTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        if dataChannel.readyState == .open { onEvent?(.channelOpen) }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        onEvent?(.message(text))
    }
}

/// Counts the face's video frames as they are handed to be drawn.
final class FrameCounter: NSObject, LKRTCVideoRenderer {
    private let lock = NSLock()
    private var frames = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        frames += 1
        lock.unlock()
    }
}

/**
 * A RECEIVED VOICE'S LEVEL, BEFORE ITS VOLUME — the decoded audio as the
 * track's renderers hear it, ahead of the gain a silenced track applies. Two
 * readings over the last quarter second: the mean absolute sample on the
 * meter scale (sqrt(meanAbs / 0.25), the web engine's `meterLevel`) and the
 * peak (0–1, as WebRTC's own `audioLevel` reads). Any thread.
 */
final class AudioLevelMeter: NSObject, LKRTCAudioRenderer {
    private let lock = NSLock()
    private var windows: [(at: TimeInterval, meanAbs: Double, peak: Double)] = []
    static let windowSeconds = 0.25

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let frames = Int(pcmBuffer.frameLength)
        guard frames > 0 else { return }
        var sum = 0.0
        var peak = 0.0
        if let data = pcmBuffer.floatChannelData {
            let p = data[0]
            for i in 0..<frames {
                let v = Double(abs(p[i]))
                sum += v
                if v > peak { peak = v }
            }
        } else if let data = pcmBuffer.int16ChannelData {
            let p = data[0]
            let stride = pcmBuffer.format.isInterleaved ? Int(pcmBuffer.format.channelCount) : 1
            for i in 0..<frames {
                let v = Double(abs(Int(p[i * stride]))) / 32768
                sum += v
                if v > peak { peak = v }
            }
        } else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        windows.append((now, sum / Double(frames), min(1, peak)))
        windows.removeAll { now - $0.at > Self.windowSeconds }
        lock.unlock()
    }

    private func recent() -> [(at: TimeInterval, meanAbs: Double, peak: Double)] {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        return windows.filter { now - $0.at <= Self.windowSeconds }
    }

    /// The meter-scale level (0–1) over the last quarter second; 0 when nothing arrived.
    func meterLevel() -> Double {
        let w = recent()
        guard !w.isEmpty else { return 0 }
        let meanAbs = w.reduce(0) { $0 + $1.meanAbs } / Double(w.count)
        return AudioLevelMeter.meterScale(meanAbs)
    }

    /// The peak (0–1) over the last quarter second; 0 when nothing arrived.
    func peakLevel() -> Double {
        recent().reduce(0) { max($0, $1.peak) }
    }

    /// The web engine's meter scale: sqrt(meanAbs / 0.25), capped at 1, to two decimals.
    static func meterScale(_ meanAbs: Double) -> Double {
        let x = meanAbs.isFinite ? max(0, meanAbs) : 0
        return (min(1, (x / 0.25).squareRoot()) * 100).rounded() / 100
    }
}
