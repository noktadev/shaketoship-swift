import Foundation
import Testing

@testable import ShakeToShip

@Suite struct DegradationEmptyCapabilitiesTests {
  @Test func emptyCapabilitiesInstallNoFeedbackRuntime() {
    let config = ShakeToShipConfig(
      app: "test", collectorURL: URL(string: "https://collector.example.com")!,
      secret: "s", capabilities: [])

    #expect(FeedbackGate.shouldAttach(config: config) == false)
    #expect(FeedbackGate.capturePlan(for: config) == .inert)
    #expect(
      FeedbackComposerRules.shakeDestination(
        capabilities: config.capabilities, recordingAvailable: true) == .none)
  }
}
