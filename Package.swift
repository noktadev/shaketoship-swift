// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "AppFeedback",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "AppFeedback", targets: ["AppFeedback"]),
    // Extension-safe subset: linkable from a ReplayKit broadcast upload
    // extension, which runs in a 50 MB process and cannot use app-only API.
    .library(name: "AppFeedbackCapture", targets: ["AppFeedbackCapture"]),
    // The broadcast upload extension's base class. Links ReplayKit, so it is
    // NOT importable from the host app's own capture path - the host links
    // AppFeedback, the .appex links this.
    .library(name: "AppFeedbackBroadcast", targets: ["AppFeedbackBroadcast"]),
  ],
  targets: [
    .target(name: "AppFeedbackCapture"),
    .target(name: "AppFeedbackBroadcast", dependencies: ["AppFeedbackCapture"]),
    .target(name: "AppFeedback", dependencies: ["AppFeedbackCapture"]),
    // Real-CMSampleBuffer factory shared by both capture-side test targets.
    // Deliberately not a product: it is reachable only from test targets, so
    // it is never built for a consumer of this package.
    .target(name: "CaptureTestSupport", path: "Tests/CaptureTestSupport"),
    .testTarget(
      name: "AppFeedbackCaptureTests", dependencies: ["AppFeedbackCapture", "CaptureTestSupport"]),
    .testTarget(
      name: "AppFeedbackBroadcastTests",
      dependencies: ["AppFeedbackBroadcast", "AppFeedbackCapture", "CaptureTestSupport"]),
    .testTarget(name: "AppFeedbackTests", dependencies: ["AppFeedback"]),
  ]
)
