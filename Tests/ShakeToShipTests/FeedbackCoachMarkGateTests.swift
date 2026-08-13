import Testing

@testable import ShakeToShip

/// The one-time "shake to record feedback" coach mark's show/dismiss decision
/// (#584 option A) - pure so the eligible/shown-once/gate-off matrix is
/// unit-tested without a live UserDefaults-backed view.
@Suite struct FeedbackCoachMarkGateTests {
  @Test func showsWhenActiveAndNeverShown() {
    #expect(FeedbackCoachMarkGate.shouldShow(recorderActive: true, alreadyShown: false) == true)
  }

  @Test func neverShowsAgainOnceShown() {
    #expect(FeedbackCoachMarkGate.shouldShow(recorderActive: true, alreadyShown: true) == false)
  }

  @Test func neverShowsWhenRecorderInactive() {
    // App Store (or a not-yet-opted-in TestFlight install): recorder inactive,
    // even if the shown-flag were somehow false - coach mark must stay hidden.
    #expect(FeedbackCoachMarkGate.shouldShow(recorderActive: false, alreadyShown: false) == false)
    #expect(FeedbackCoachMarkGate.shouldShow(recorderActive: false, alreadyShown: true) == false)
  }
}
