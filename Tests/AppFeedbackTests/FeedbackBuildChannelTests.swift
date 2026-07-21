import XCTest

@testable import AppFeedback

final class FeedbackBuildChannelTests: XCTestCase {
  func test_debugWinsOverAnyReceipt() {
    XCTAssertEqual(
      FeedbackBuildChannel.resolve(isDebugBuild: true, receiptLastPathComponent: "sandboxReceipt"),
      .debug)
    XCTAssertEqual(
      FeedbackBuildChannel.resolve(isDebugBuild: true, receiptLastPathComponent: "receipt"),
      .debug)
    XCTAssertEqual(
      FeedbackBuildChannel.resolve(isDebugBuild: true, receiptLastPathComponent: nil),
      .debug)
  }

  func test_release_sandboxReceiptIsTestFlight() {
    XCTAssertEqual(
      FeedbackBuildChannel.resolve(isDebugBuild: false, receiptLastPathComponent: "sandboxReceipt"),
      .testFlight)
  }

  func test_release_storeReceiptIsAppStore() {
    XCTAssertEqual(
      FeedbackBuildChannel.resolve(isDebugBuild: false, receiptLastPathComponent: "receipt"),
      .appStore)
  }

  func test_release_missingReceiptFailsClosedToAppStore() {
    XCTAssertEqual(
      FeedbackBuildChannel.resolve(isDebugBuild: false, receiptLastPathComponent: nil),
      .appStore)
  }

  func test_currentIsDebugUnderTests() {
    XCTAssertEqual(FeedbackBuildChannel.current, .debug)
  }
}
