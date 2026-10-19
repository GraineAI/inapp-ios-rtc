# GraineInAppRTC for iOS

WebRTC audio for the native calls of [GraineInApp](https://github.com/GraineAI/inapp-ios)
(iOS 15+): the calls the customer places to your agent and the calls your agent
rings them with, on CallKit and VoIP pushes. Add this package beside
GraineInApp and those calls carry their audio over WebRTC — a jitter buffer,
loss concealment and the platform's echo canceller — instead of the WebSocket.
Nothing else in your app changes.

## Install

In Xcode: **File → Add Package Dependencies…**, enter
`https://github.com/GraineAI/inapp-ios-rtc`, and add the `GraineInAppRTC`
library to the target that uses `GraineInApp`. In a `Package.swift`:

```swift
.package(url: "https://github.com/GraineAI/inapp-ios", from: "0.12.0"),
.package(url: "https://github.com/GraineAI/inapp-ios-rtc", from: "0.12.0")
```

Always the same version as GraineInApp. With CocoaPods: `pod 'GraineInAppRTC'`.

That is all: no code, no `Info.plist` entry, no capability beyond the calls'
own. The calls find the module at runtime. A build that strips code nothing
references can make sure of it at launch:

```swift
import GraineInAppRTC

GraineRTC.install()
```

## What it does

- A call tries WebRTC when this module is in the app and
  `GraineCallsConfig.callTransport` allows it (`.auto`, the default). The
  agent's **In-app call audio** setting in the dashboard can move its calls back
  to the WebSocket without an app release.
- A call WebRTC cannot carry continues on the WebSocket inside the same call —
  no second ring — and `calls.transportFallbackReason` says why. A call the
  agent cannot take at all (no credit, the agent switched off) ends with that
  reason.
- The agent sees the screen you describe, runs your actions and captions the
  call exactly as on the WebSocket.

Integration guide: https://www.graine.ai/docs/in-app/ios

## Size and licences

About 12 MB more installed on an arm64 iPhone and about 6 MB more to download,
almost all of it the prebuilt WebRTC library this package depends on. Its
licences are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md): include them in
your app's open-source notices. If another package in your app pins
`webrtc-xcframework` to a different version, the two cannot be resolved
together.

## Tests

`swift test` runs the SIP, media-rule and engine tests on a Mac with no
network. A real call against your agent, opt-in, the key from the environment
only:

```sh
GRAINE_LIVE_RTC=1 GRAINE_LIVE_RTC_KEY=<publishable key> swift test --filter RtcLiveTests
```
