import Testing

@testable import ShakeToShip

@Suite struct FeedbackHUDStateTests {
  @Test func recordingTooLargeUsesTheRequiredStatusText() {
    let state = FeedbackHUDState.status(for: .recordingTooLarge, confirmed: true)

    #expect(state.text == "Recording too large to send")
  }

  @Test func launchSweepSurfacesTheRecordingTooLargeStatus() {
    let sweep = OutboxSweepResult(
      flushed: 1, queued: 1, purged: 0, recordingTooLarge: 1,
      rejected: 1)

    let state = FeedbackHUDState.status(for: sweep)

    #expect(state?.text == "Recording too large to send")
  }
}
