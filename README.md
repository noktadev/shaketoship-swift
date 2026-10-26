# ShakeToShip

Native support chat and screen-recorded feedback for iOS. Users can describe a problem, suggest an idea, or select **Let me show you** to use the recorder.

Requires iOS 17+ and Swift 6 tools. The package also supports macOS 14 for shared logic; the recorder and hub use iOS presentation. AppUploads is included. No private package dependency is required.

## Install

```swift
.package(url: "https://github.com/noktadev/shaketoship-swift", from: "3.0.0")
```

Link the `ShakeToShip` product and use `import ShakeToShip`. The old `AppFeedback`, `FeedbackConfig`, and `.feedbackRecorder(config:)` names do not describe the 3.0 API.

## Support chat

```swift
import SwiftUI
import ShakeToShip

RootView()
  .shakeToShip(config: ShakeToShipConfig(
    app: "com.example.myapp",
    collectorURL: URL(string: "https://ingest.shaketoship.com")!,
    secret: uploadToken,
    capabilities: .microphoneFree,
    hub: [.support]
  ))
```

Use your app's bundle identifier and the project upload token from the [dashboard](https://shaketoship.com/app). Inject the token through build configuration; do not commit a literal token.

The host controls activation and consent. A nil configuration or empty capabilities disables attachment. The hub also requires nonempty hub options; they default to empty. `.microphoneFree` enables screen recording, library attachments, and text without microphone capture. Select capabilities and configure the relevant iOS permission descriptions before enabling microphone access.

Text choices add an editable prompt. They do not send automatically. **Let me show you** uses the registered recorder and its consent controls. Message input and attachment controls remain visible during delivery. Actual screen and microphone capture require device testing.

The service stores private conversations and can ask for more detail or acknowledge clear feedback. View the transcript under your dashboard project's **Conversations** section. Recording messages link to their recording and analysis. These conversations do not automatically publish ideas or create GitHub issues. The dashboard does not yet support owner replies in the same chat.

## Upgrading from 2.x

3.0 changes the public API. Update imports and configuration as shown above. The support hub is opt-in. Hosts with old recorder uploads can use `allowsLegacyCaptures: true` to drain legacy captures without assigning them to the new reporter identity.

If you operate the backend, apply migrations 0033–0035 and deploy both API workers before adopting conversations. Hosted backend configuration must permit the app and token. A new SDK version alone does not enable a disabled host gate.

## Source and releases

This repository mirrors the SDK source from the Nokta apps monorepo. Version tags are immutable. Minor and major versions require explicit release approval; patch versions are published by the mirror workflow.
