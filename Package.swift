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
  ],
  targets: [
    .target(name: "AppFeedbackCapture"),
    .target(name: "AppFeedback", dependencies: ["AppFeedbackCapture"]),
    .testTarget(name: "AppFeedbackCaptureTests", dependencies: ["AppFeedbackCapture"]),
    .testTarget(name: "AppFeedbackTests", dependencies: ["AppFeedback"]),
  ]
)
