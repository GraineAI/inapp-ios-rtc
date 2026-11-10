#if os(iOS)
import AVFoundation
import LiveKitWebRTC
import Testing
@testable import GraineInAppRTC

/*
 * WHAT WEBRTC APPLIES TO A CALL IS THE CALL'S (RtcAudioGate.pinCallConfiguration). This WebRTC build copies the app's
 * audio category and mode into the configuration it applies to every call, once per launch, when it is first read. A
 * booked call ringing an app the push had just started found it solo ambient, and every call in that launch went
 * silent and ended at about 5 s (10 Nov 2026). Here WebRTC is given that captured configuration, as such a launch has
 * it; a leg must hand WebRTC play and record, voice chat, Bluetooth headsets, and give the app's own back after.
 */
@Suite(.serialized) struct RtcCallConfigurationTests {
    private static var bluetooth: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        return .allowBluetoothHFP
        #else
        return .allowBluetooth
        #endif
    }

    private func soloAmbient() -> LKRTCAudioSessionConfiguration {
        let captured = LKRTCAudioSessionConfiguration()
        captured.category = AVAudioSession.Category.soloAmbient.rawValue
        captured.mode = AVAudioSession.Mode.default.rawValue
        return captured
    }

    @Test func aLegGivesWebRTCTheCallsConfigurationWhateverItReadFirst() {
        let captured = soloAmbient()
        LKRTCAudioSessionConfiguration.setWebRTC(captured)
        let gate = RtcAudioGate.shared
        gate.callBegins()
        let during = LKRTCAudioSessionConfiguration.webRTC()
        #expect(during.category == AVAudioSession.Category.playAndRecord.rawValue)
        #expect(during.mode == AVAudioSession.Mode.voiceChat.rawValue)
        #expect(during.categoryOptions.contains(Self.bluetooth))
        #expect(during.sampleRate == captured.sampleRate, "only the call's mode changes: WebRTC's own rates are kept")
        gate.callEnds()
        #expect(LKRTCAudioSessionConfiguration.webRTC() === captured, "the app's own configuration comes back after the last leg")
    }

    @Test func overlappingLegsKeepTheCallsConfigurationUntilTheLastEnds() {
        let captured = soloAmbient()
        LKRTCAudioSessionConfiguration.setWebRTC(captured)
        let gate = RtcAudioGate.shared
        gate.callBegins()   // a ring's prepared leg
        gate.callBegins()   // the answer's
        gate.callEnds()
        #expect(LKRTCAudioSessionConfiguration.webRTC().category == AVAudioSession.Category.playAndRecord.rawValue,
                "a leg still holds the gate: still the call's")
        gate.callEnds()
        #expect(LKRTCAudioSessionConfiguration.webRTC() === captured)
    }

    @Test func aConfigurationAlreadyTheCallsIsLeftAsItIs() {
        let call = LKRTCAudioSessionConfiguration()
        call.category = AVAudioSession.Category.playAndRecord.rawValue
        call.mode = AVAudioSession.Mode.voiceChat.rawValue
        call.categoryOptions = [Self.bluetooth]
        LKRTCAudioSessionConfiguration.setWebRTC(call)
        let gate = RtcAudioGate.shared
        gate.callBegins()
        #expect(LKRTCAudioSessionConfiguration.webRTC() === call, "nothing to change: the same object stays")
        gate.callEnds()
        #expect(LKRTCAudioSessionConfiguration.webRTC() === call)
    }
}
#endif
