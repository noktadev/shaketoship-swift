import Foundation
import Testing

@testable import AppFeedbackBroadcast

/// The extension has no UI and no way to ask anyone anything: whatever it can
/// read out of its own Info.plist at launch is all the configuration it will
/// ever get. Everything here is about failing legibly when that is wrong,
/// rather than minting a session into a container nobody will look in.
@Suite struct FeedbackBroadcastConfigurationTests {
  @Test func readsTheHostBundleIdAndCapFromTheInfoDictionary() throws {
    let config = try #require(
      FeedbackBroadcastConfiguration(
        infoDictionary: [
          "AppFeedbackHostBundleId": "com.example.app",
          "AppFeedbackCapSeconds": 120,
        ]))
    #expect(config.hostBundleId == "com.example.app")
    #expect(config.capSeconds == 120)
  }

  @Test func failsWithoutAHostBundleIdRatherThanGuessingOne() {
    // The App Group id is derived from this. A guess would resolve to a
    // container the host app never reads, so every recording would be written
    // perfectly and then lost.
    #expect(FeedbackBroadcastConfiguration(infoDictionary: [:]) == nil)
    #expect(FeedbackBroadcastConfiguration(infoDictionary: ["AppFeedbackHostBundleId": ""]) == nil)
    #expect(
      FeedbackBroadcastConfiguration(infoDictionary: ["AppFeedbackHostBundleId": 42]) == nil)
  }

  @Test func fallsBackToTheDefaultCapWhenItIsAbsentOrUnusable() throws {
    let absent = try #require(
      FeedbackBroadcastConfiguration(infoDictionary: ["AppFeedbackHostBundleId": "com.example.app"]))
    #expect(absent.capSeconds == FeedbackBroadcastConfiguration.defaultCapSeconds)

    // A zero or negative cap would make the sink refuse the very first buffer
    // (elapsed >= maxDuration on frame one), producing an empty recording for
    // what is almost certainly a typo in a plist.
    for bad in [0, -30] as [Any] {
      let config = try #require(
        FeedbackBroadcastConfiguration(
          infoDictionary: ["AppFeedbackHostBundleId": "com.example.app", "AppFeedbackCapSeconds": bad]))
      #expect(config.capSeconds == FeedbackBroadcastConfiguration.defaultCapSeconds)
    }
  }

  @Test func acceptsACapWrittenAsAStringBecausePlistEditorsProduceThose() throws {
    let config = try #require(
      FeedbackBroadcastConfiguration(
        infoDictionary: [
          "AppFeedbackHostBundleId": "com.example.app",
          "AppFeedbackCapSeconds": "300",
        ]))
    #expect(config.capSeconds == 300)
  }

  @Test func reportsAnSdkVersionForTheManifest() throws {
    let config = try #require(
      FeedbackBroadcastConfiguration(infoDictionary: ["AppFeedbackHostBundleId": "com.example.app"]))
    // Stamped into every manifest so the server can tell which capture build
    // produced a file it cannot parse.
    #expect(config.sdkVersion.isEmpty == false)
  }
}
