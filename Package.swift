// swift-tools-version:6.0
// The public mirror vendors the shared target; it cannot use a private sibling path.
import PackageDescription

let package = Package(
  name: "ShakeToShip",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "ShakeToShip", targets: ["ShakeToShip"])],
  targets: [
    .target(name: "AppUploads"),
    .target(name: "ShakeToShip", dependencies: ["AppUploads"],
      resources: [.process("PrivacyInfo.xcprivacy")]),
    .testTarget(name: "ShakeToShipTests", dependencies: ["ShakeToShip"]),
    .testTarget(name: "AppUploadsTests", dependencies: ["AppUploads"]),
  ]
)
