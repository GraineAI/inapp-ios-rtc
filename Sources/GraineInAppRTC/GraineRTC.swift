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
}
