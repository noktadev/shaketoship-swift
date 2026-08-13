import XCTest

@testable import ShakeToShip

final class FeedbackRecordingCopyTests: XCTestCase {
  func testActiveRecordingCopyTellsTheUserToSpeakNow() {
    XCTAssertEqual(FeedbackRecordingCopy.activePrompt, "Speak now - tell us what happened")
    XCTAssertEqual(
      FeedbackRecordingCopy.activeAccessibilityLabel,
      "Speak now. Tell us what happened. Feedback is recording. Tap to stop.")
  }

  func testPromptExplainsNarrationBeforeRecordingStarts() {
    XCTAssertEqual(
      FeedbackRecordingCopy.promptExplanation,
      "When recording starts, speak and show us what happened. Shake again or tap stop to finish."
    )
  }

  func testCoachMarkMessageIsExactShakeCopy() {
    XCTAssertEqual(
      FeedbackRecordingCopy.coachMarkMessage, "Shake your phone anytime to record feedback")
  }
}
