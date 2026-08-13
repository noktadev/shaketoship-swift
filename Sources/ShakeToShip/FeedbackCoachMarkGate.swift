import Foundation

/// Pure show/dismiss decision for the one-time "shake to record feedback"
/// coach mark (#584 option A). Kept dependency-free like `FeedbackGate` so the
/// eligible/shown-once/gate-off matrix is unit-tested without a live
/// UserDefaults-backed view. `recorderActive` is the caller's
/// `activeConfig(...) != nil` result - the exact same gate the recorder
/// itself attaches on - so this can never show when the recorder is inert
/// (App Store, or gate off).
public enum FeedbackCoachMarkGate {
  public static func shouldShow(recorderActive: Bool, alreadyShown: Bool) -> Bool {
    recorderActive && !alreadyShown
  }
}
