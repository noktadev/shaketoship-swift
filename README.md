# shaketoship-swift

Shake-to-record feedback SDK for iOS. Users shake the device, narrate what's
wrong while the SDK captures screen + audio, and [shaketoship](https://shaketoship.com)
turns the recording into a structured GitHub issue your coding agent can fix.

- iOS 17+ / macOS 14+, Swift 6 tools
- Screen + mic recording with a Live Activity recording bar
- Tap/screen event trail alongside the video
- Background-safe uploads (presign + direct PUT), retry sweep on next launch
- Zero third-party dependencies (Apple frameworks only)

## Install

Add the package in Xcode (File > Add Package Dependencies) or in `Package.swift`:

```swift
.package(url: "https://github.com/noktadev/shaketoship-swift", from: "0.1.0"),
```

Product to link: `AppFeedback`.

## Quickstart

Attach the recorder at your SwiftUI root:

```swift
import AppFeedback

@main
struct MyApp: App {
  var body: some Scene {
    WindowGroup {
      RootView()
        .feedbackRecorder(config: FeedbackConfig(
          app: "my-app",                                        // your shaketoship project's app id
          collectorURL: URL(string: "https://ingest.shaketoship.com")!,
          secret: uploadToken                                    // project upload token - keep out of source control
        ))
    }
  }
}
```

`secret` is your project's **upload token** from the shaketoship dashboard
(Tokens tab). Inject it via an xcconfig / build setting / gitignored plist -
never commit it as a source literal. Passing `nil` as the config disables the
recorder entirely (e.g. for App Store builds where you gate feedback to
TestFlight channels).

Shake to start recording, shake (or tap the recording bar) to stop. The
recording uploads to your shaketoship project and lands as a session with
video, narration analysis, and a filed GitHub issue once a repo is connected.

### Live Activity (optional)

The recording bar can run as a Live Activity so the user sees recording state
outside the app. Add a widget extension target that renders
`FeedbackRecordingAttributes` if you want that; without it the in-app bar
still works.

## How it relates to the platform

| Piece | Where |
| --- | --- |
| This SDK | records + uploads sessions |
| `ingest.shaketoship.com` | receives uploads (presign + PUT) |
| Dashboard | [app.shaketoship.com](https://app.shaketoship.com/app) - projects, tokens, sessions, issues |
| `sts` CLI | `npm i -g shaketoship` - agent-driven project setup |

## License

MIT
