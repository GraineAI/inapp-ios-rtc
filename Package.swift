// swift-tools-version:5.9
//
// GRAINE IN-APP CALLS ON WEBRTC, FOR NATIVE iOS — the opt-in companion of
// GraineInApp.
//
// Add this package beside GraineInApp and the native calls (CallKit, VoIP
// pushes) carry their audio over WebRTC; nothing else in the app changes, and a
// call WebRTC cannot carry continues on the WebSocket. It is its own package,
// not a product of GraineInApp's: SwiftPM fetches every binary of a package for
// every app that uses any of its products, so the WebRTC binary there would
// reach — and could conflict in — apps that never asked for it. GraineInApp
// stays without a single dependency.
import PackageDescription

// GraineInApp, of exactly the same version (the two talk through its SPI): this
// repository's own ../ios while it is developed; publish-sdk-repo.sh writes the
// released package's URL and version here in the export.
let core: Package.Dependency = .package(url: "https://github.com/GraineAI/inapp-ios.git", exact: "0.10.3")
let corePackage = "inapp-ios"

let package = Package(
    name: "GraineInAppRTC",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        // The Mac only runs the tests (and the opt-in live test); swift-testing needs macOS 14.
        .macOS(.v14),
    ],
    products: [
        .library(name: "GraineInAppRTC", targets: ["GraineInAppRTC"]),
    ],
    dependencies: [
        core,
        // A maintained, symbol-prefixed build of Google's libwebrtc (classes LKRTC…), pinned exactly.
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", exact: "150.7871.03"),
    ],
    targets: [
        .target(
            name: "GraineInAppRTC",
            dependencies: [
                .product(name: "GraineInApp", package: corePackage),
                .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
            ],
            path: "Sources/GraineInAppRTC",
            // Its own privacy manifest: this module times the call's steps on the uptime clock.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "GraineInAppRTCTests",
            dependencies: ["GraineInAppRTC"],
            path: "Tests/GraineInAppRTCTests"
        ),
    ]
)
