import Foundation

/// Pure start-race guard for the shake recorder (#453).
///
/// `startRecording` awaits ReplayKit's `startCapture` BEFORE it publishes
/// `isRecording = true`. If the scene deactivates (background / gate flip)
/// during that await, the modifier's `isRecording`-gated teardown is a no-op and
/// a capture can begin while the app believes it is idle - violating the
/// inert-when-gated invariant. ReplayKit's continuation is not cancellation
/// aware, so instead of cancelling the start we let it complete and then check
/// this guard: a start that began before a deactivation must immediately stop.
///
/// It also models scene active/inactive explicitly: a `begin()` requested while
/// the scene is inactive (e.g. a `startRecording` queued from the prompt sheet's
/// `onDismiss` that only runs after a backgrounding / `onDisappear`) is REJECTED
/// outright - it returns nil and no capture is started, because there is no
/// future teardown event to stop it. `activate()` re-arms starts on appear /
/// `didBecomeActive`.
///
/// Kept pure and value-typed (like `FeedbackGate`) so the race decision is
/// unit-tested without a live responder chain, ReplayKit, or SwiftUI @State.
struct FeedbackStartGuard {
  /// Monotonic id handed to each start; also the "generation" a deactivation
  /// records so it only invalidates starts already in flight, never future ones.
  private var epoch: UInt64 = 0
  /// The epoch that was current at the last `deactivate()`. Any start whose
  /// token is <= this must abort; a start begun afterwards (higher token) is
  /// unaffected.
  private var deactivatedEpoch: UInt64?
  /// Whether the scene is currently active. Starts begin active; `deactivate()`
  /// clears it and `activate()` re-arms it. A `begin()` while inactive is refused.
  private var active = true

  /// Reserve the next start generation, or nil when the scene is inactive so the
  /// caller does NOT start a capture. Call before awaiting `rec.start`.
  mutating func begin() -> UInt64? {
    guard active else { return nil }
    epoch &+= 1
    return epoch
  }

  /// Record that the scene deactivated. Invalidates every start begun up to now
  /// AND refuses any new `begin()` until `activate()`.
  mutating func deactivate() {
    active = false
    deactivatedEpoch = epoch
  }

  /// Scene became active again (appear / `didBecomeActive`): allow starts again.
  mutating func activate() {
    active = true
  }

  /// Whether a start that reserved `startedEpoch` must abort because a
  /// deactivation landed at or after it began.
  func shouldAbort(startedEpoch: UInt64) -> Bool {
    guard let deactivatedEpoch else { return false }
    return deactivatedEpoch >= startedEpoch
  }
}
