import XCTest

@testable import AppFeedback

/// The "shake again to stop" hint's show/dismiss decision (#1092) - pure so
/// the show-on-start / auto-clear / stop-clears matrix is unit-tested without
/// a live view or timer.
final class FeedbackShakeHintGateTests: XCTestCase {
  func testRecordingStartedShowsTheHint() {
    XCTAssertTrue(FeedbackShakeHintGate.reduce(isVisible: false, event: .recordingStarted))
  }

  func testTimerElapsedAutoClearsTheHint() {
    XCTAssertFalse(FeedbackShakeHintGate.reduce(isVisible: true, event: .timerElapsed))
  }

  func testRecordingStoppedClearsAVisibleHint() {
    XCTAssertFalse(FeedbackShakeHintGate.reduce(isVisible: true, event: .recordingStopped))
  }

  func testRecordingStoppedNeverShowsTheHint() {
    // A normal stop must never surface the hint, whether or not it was
    // already showing - it only ever exists to explain an in-progress
    // recording.
    XCTAssertFalse(FeedbackShakeHintGate.reduce(isVisible: false, event: .recordingStopped))
  }

  func testVisibleDurationIsFourSeconds() {
    XCTAssertEqual(FeedbackShakeHintGate.visibleDuration, 4)
  }
}
