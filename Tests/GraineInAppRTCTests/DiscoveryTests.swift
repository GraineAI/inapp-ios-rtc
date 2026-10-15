import Foundation
import Testing
@_spi(GraineRTC) @testable import GraineInApp
@testable import GraineInAppRTC

/*
 * AN APP THAT ADDS THE MODULE CHANGES NOTHING ELSE: GraineInApp, which never
 * imports it, finds it at runtime by its Objective-C class name — and
 * `GraineRTC.install()` registers it explicitly for a build that strips code
 * nothing references.
 */
@Suite(.serialized) struct DiscoveryTests {
    @Test func theCoreFindsTheModuleByItsClassName() {
        GraineRtcRegistry.reset()
        #expect(NSClassFromString(GraineRtcRegistry.className) != nil, "the stable name is in the Objective-C runtime")
        let found = GraineRtcRegistry.module
        #expect(found is GraineInAppRTCModule)
        #expect(found?.isSupported == true)
        let call = found?.makeCall(GraineRtcRequest(baseUrl: "https://www.graine.ai", controlHost: "wss://ws.graine.ai", mintBody: { _ in Data() }, sdkVersion: "0.7.0"))
        #expect(call is RtcCallEngine)
        GraineRtcRegistry.reset()
    }

    @Test func installRegistersItExplicitly() {
        GraineRtcRegistry.reset()
        GraineRTC.install()
        #expect(GraineRtcRegistry.module is GraineInAppRTCModule)
        GraineRtcRegistry.reset()
    }

    @Test func theVersionIsTheCoresVersion() {
        #expect(GraineRTCVersion.name == GraineVersion.name, "released together: bump-version moves both")
    }
}
