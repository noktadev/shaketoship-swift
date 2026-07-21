import XCTest

@testable import AppFeedback

/// The failure vocabulary is platform-neutral on purpose (see
/// `FeedbackLiveActivityStartFailure`): the controller that produces it is
/// device-only, so these reasons are the only part of the start path that can be
/// pinned down on the macOS host.
final class FeedbackLiveActivityStartFailureTests: XCTestCase {
  /// The reason strings ride into analytics via
  /// `FeedbackFunnelEvent.liveActivityStartFailed(reason:)`, so they are wire
  /// values: renaming one silently breaks every dashboard built on the old name.
  func testReasonWireValuesAreStable() {
    XCTAssertEqual(FeedbackLiveActivityStartFailure.activitiesDisabled.rawValue, "activities-disabled")
    XCTAssertEqual(FeedbackLiveActivityStartFailure.requestFailed.rawValue, "request-failed")
  }

  /// #557: the two failure modes must stay distinguishable. "User switched Live
  /// Activities off" and "ActivityKit refused the request" look identical from
  /// the outside (no banner) but need opposite responses, and collapsing them
  /// back into one silent nil is exactly the bug this vocabulary exists to end.
  func testFailureModesAreDistinct() {
    XCTAssertNotEqual(
      FeedbackLiveActivityStartFailure.activitiesDisabled,
      FeedbackLiveActivityStartFailure.requestFailed)
    XCTAssertEqual(Set(FeedbackLiveActivityStartFailure.allCases).count, 2)
  }

  /// The funnel event carries the reason through unchanged - the host app maps
  /// this straight onto its analytics client.
  func testFunnelEventCarriesReason() {
    let event = FeedbackFunnelEvent.liveActivityStartFailed(
      reason: FeedbackLiveActivityStartFailure.activitiesDisabled.rawValue)
    XCTAssertEqual(event, .liveActivityStartFailed(reason: "activities-disabled"))
    XCTAssertNotEqual(event, .liveActivityStartFailed(reason: "request-failed"))
  }
}
