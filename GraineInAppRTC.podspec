# GraineInAppRTC for apps that install with a Podfile: the opt-in WebRTC module
# for GraineInApp's native calls.
#
# Swift Package Manager (Package.swift) is the primary install. This spec builds
# exactly what the Swift package builds: the same sources, iOS 15, Swift 5.9,
# its own privacy manifest, the same pinned WebRTC binary. Its version is read
# from Sources/GraineInAppRTC/Version.swift, which bump-version keeps equal to
# GraineInApp's, and it depends on GraineInApp of exactly that version.
version = File.read(File.join(__dir__, "Sources", "GraineInAppRTC", "Version.swift"))[/static let name = "([^"]+)"/, 1]
raise "Sources/GraineInAppRTC/Version.swift does not say which version this is" unless version

Pod::Spec.new do |s|
  s.name              = "GraineInAppRTC"
  s.version           = version
  s.summary           = "WebRTC audio for the Graine in-app agent's native calls."
  s.description       = <<~DESC
    The opt-in WebRTC module for GraineInApp's native calls (CallKit and VoIP
    pushes): the call's audio travels over WebRTC, with a jitter buffer, loss
    concealment and the platform's echo canceller, and falls back to the
    WebSocket by itself when WebRTC cannot carry a call. Add it to the target
    that uses GraineInApp; nothing else changes.
  DESC
  s.homepage          = "https://www.graine.ai/docs/in-app/ios"
  s.documentation_url = "https://www.graine.ai/docs/in-app/ios"
  s.license           = { :type => "MIT", :file => "LICENSE" }
  s.author            = { "Graine AI" => "support@graine.ai" }
  # The tag publish-sdk-repo.sh pushes for this version.
  s.source            = { :git => "https://github.com/GraineAI/inapp-ios-rtc.git", :tag => s.version.to_s }

  s.ios.deployment_target = "15.0"
  s.swift_versions    = ["5.9"]

  s.source_files      = "Sources/GraineInAppRTC/**/*.swift"
  s.resource_bundles  = { "GraineInAppRTC_Privacy" => ["Sources/GraineInAppRTC/PrivacyInfo.xcprivacy"] }
  s.frameworks        = "AVFoundation", "CryptoKit"

  s.dependency "GraineInApp", version
  # A prebuilt, symbol-prefixed build of Google's libwebrtc: pinned exactly, as in Package.swift.
  s.dependency "LiveKitWebRTC", "150.7871.03"
end
