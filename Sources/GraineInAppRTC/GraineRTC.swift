@_spi(GraineRTC) import GraineInApp
import Foundation

/**
 * NATIVE CALLS ON WEBRTC — add the `GraineInAppRTC` product to the app's
 * target and the calls (`GraineInApp.shared.calls`) carry their audio over
 * WebRTC: a jitter buffer, loss concealment and the platform's echo canceller,
 * on a network that drops packets. Nothing else changes in the app: the SDK
 * finds this module by itself, and a call that cannot be carried on WebRTC
 * continues on the WebSocket inside the same system call.
 *
 *     // Optional: only for a build that strips code nothing references.
 *     GraineRTC.install()
 *
 * `GraineCallsConfig.callTransport` chooses (`auto` by default); the dashboard
 * can turn WebRTC off for an agent without an app release.
 */
public enum GraineRTC {
    /// Make WebRTC available to the calls now, rather than when the first call looks for it.
    public static func install() {
        GraineRtcRegistry.install(GraineInAppRTCModule())
    }
}

/**
 * The module as the SDK finds it at runtime: its Objective-C name is part of
 * the contract with GraineInApp (`GraineRtcRegistry.className`) — never rename it.
 */
@objc(GraineInAppRTCModule)
final class GraineInAppRTCModule: NSObject, GraineRtcModule {
    override init() {
        super.init()
    }

    /// The package's own minimums (iOS 15, macOS 14) are above what libwebrtc needs.
    var isSupported: Bool { true }

    func makeCall(_ request: GraineRtcRequest) -> GraineRtcCall {
        RtcCallEngine(request: request, parts: .production())
    }

    /// A grant for the direct mint — the next call's, or a ringing call's — and the gateway asked whether it takes one (Engine/RtcDirectMint.swift).
    func warmUp(_ request: GraineRtcRequest, log: ((String) -> Void)?) {
        RtcDirectMint.shared.warm(baseUrl: request.baseUrl, body: request.mintBody(""), log: log)
    }

    /// The id the next call's grant was asked for, while it is usable: the call being placed takes it.
    func nextCallId(_ request: GraineRtcRequest) -> String? {
        RtcDirectMint.shared.takeCallId(baseUrl: request.baseUrl, body: request.mintBody(""))
    }

    /// CallKit took the audio session back after its call was over: WebRTC's view of the session follows (Engine/RtcAudioGate.swift).
    func audioSessionDeactivated() {
        #if os(iOS)
        RtcAudioGate.shared.sessionDeactivated()
        #endif
    }
}
