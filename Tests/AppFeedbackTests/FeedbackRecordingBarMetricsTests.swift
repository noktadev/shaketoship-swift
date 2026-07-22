import Foundation
import Testing

@testable import AppFeedback

/// #357: a user on device reported the recording indicator was too small to
/// read ("the indicators a little bit too small"). The bar drew a flat 9pt dot.
/// These pin the legibility floor so a later tidy-up cannot shrink it back
/// below what a person can see mid-recording.
@Suite struct FeedbackRecordingBarMetricsTests {
  @Test func indicatorReadsAtLeastAtTheLegibilityFloor() {
    #expect(
      FeedbackRecordingBarMetrics.haloDiameter
        >= FeedbackRecordingBarMetrics.minimumLegibleDiameter)
  }

  @Test func coreIsLargerThanTheOriginalNinePointDot() {
    #expect(FeedbackRecordingBarMetrics.coreDiameter > 9)
  }

  @Test func coreFitsInsideTheHalo() {
    #expect(FeedbackRecordingBarMetrics.coreDiameter < FeedbackRecordingBarMetrics.haloDiameter)
  }
}
