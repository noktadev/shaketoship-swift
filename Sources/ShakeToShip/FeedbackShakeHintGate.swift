import Foundation

/// Pure show/dismiss decision for the "shake again to stop" hint (#1092): a
/// user who shakes to START a recording has no other cue that shaking again
/// is how they stop it. Kept dependency-free like `FeedbackGate` /
/// `FeedbackCoachMarkGate` so the show/auto-clear/stop-clears matrix is
/// unit-tested without a live view or timer.
enum FeedbackShakeHintGate {
  /// How long the hint stays visible once shown, absent an earlier dismissal.
  static let visibleDuration: TimeInterval = 4

  /// Inputs the caller reacts to; each maps to a new visibility below.
  enum Event {
    /// A recording just started.
    case recordingStarted
    /// The auto-dismiss timer elapsed.
    case timerElapsed
    /// The recording stopped (user shake/tap, cap, pause, or interruption) -
    /// the hint must never linger once nothing is being recorded.
    case recordingStopped
  }

  /// Reduces the current visibility + an event to the next visibility.
  /// Stateless and total: every event has exactly one outcome, independent of
  /// `isVisible`, so "never shows when recording stops normally" holds even
  /// if `recordingStopped` arrives while the hint was already hidden.
  static func reduce(isVisible: Bool, event: Event) -> Bool {
    switch event {
    case .recordingStarted: return true
    case .timerElapsed: return false
    case .recordingStopped: return false
    }
  }
}
