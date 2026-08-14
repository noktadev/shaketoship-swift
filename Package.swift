// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "ShakeToShip",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "ShakeToShip", targets: ["ShakeToShip"])],
  targets: [
    .target(
      name: "ShakeToShip",
      resources: [.process("PrivacyInfo.xcprivacy")]
    ),
    .testTarget(name: "ShakeToShipTests", dependencies: ["ShakeToShip"]),
  ]
)
