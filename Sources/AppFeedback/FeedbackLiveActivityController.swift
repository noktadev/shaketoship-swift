// iOS-device/simulator only: ActivityKit types are unavailable in macOS AND in
// Mac Catalyst (where `os(iOS)` is true) despite `canImport`.
#if os(iOS) && !targetEnvironment(macCatalyst)
// `Activity` is a reference type ActivityKit has not audited for Sendable;
// `@preconcurrency` downgrades its Sendable diagnostics to warnings so the
// queue's work closures can capture it, matching Apple's own migration
// guidance for pre-Swift-6 framework types.
@preconcurrency import ActivityKit
import Foundation

/// Thin device-only wrapper around ActivityKit for the feedback recorder.
/// Started only by DEBUG builds. NOT unit tested (ActivityKit is device-only);
/// kept minimal. Never emits analytics.
@available(iOS 16.2, *)
enum FeedbackLiveActivityController {
  /// One queue for the whole recorder: update/end run in call order, so a late
  /// update cannot land after end and screen counts cannot regress.
  @MainActor private static let queue = FeedbackSerialQueue()

  /// Requests a new Live Activity, seeded at `screenCount` (the trail's seeded
  /// event count) so the widget does not show "0 screens" for a recording that
  /// already started on a screen.
  ///
  /// Returns nil when activities are disabled by the user or the request throws,
  /// and reports WHICH of those happened via `onFailure` (#557). Both modes look
  /// identical from the outside - no banner - so swallowing them left a user
  /// reporting "not visible for me" with nothing to diagnose from. A failure is
  /// never fatal: the recording runs regardless.
  ///
  /// #943: async because both daemon round-trips it makes (the authorization
  /// read and `Activity.request` itself) now run OFF the MainActor. The caller
  /// is the shake-to-record start path; a stalled activity daemon there parked
  /// the main thread in `mach_msg` (Sentry `App Hang Fully Blocked`). The
  /// failure callback still fires on the MainActor, exactly once, after the
  /// request settles - so #557's routing is unchanged from the caller's side.
  @MainActor
  static func start(
    startedAt: Date,
    screenCount: Int,
    onFailure: (FeedbackLiveActivityStartFailure) -> Void = { _ in }
  ) async -> Activity<FeedbackRecordingAttributes>? {
    guard await activitiesEnabled() else {
      onFailure(.activitiesDisabled)
      return nil
    }
    let state = FeedbackRecordingAttributes.ContentState(
      startedAt: startedAt, screenCount: screenCount)
    guard let activity = await requestActivity(state: state) else {
      onFailure(.requestFailed)
      return nil
    }
    return activity
  }

  /// Off-MainActor read of the authorization flag: also a daemon round-trip.
  /// `Task.detached` rather than a plain `nonisolated` async func, because the
  /// latter's executor is exactly what the `NonisolatedNonsendingByDefault`
  /// upcoming feature flips - a detached task can never silently start running
  /// back on the caller's actor.
  private static func activitiesEnabled() async -> Bool {
    await Task.detached(priority: .userInitiated) {
      ActivityAuthorizationInfo().areActivitiesEnabled
    }.value
  }

  /// Off-MainActor `Activity.request`. Returns nil on throw; the concrete error
  /// is deliberately not forwarded to the caller (it reaches analytics, and
  /// ActivityKit's localized strings are user/locale text, not wire data).
  private static func requestActivity(
    state: FeedbackRecordingAttributes.ContentState
  ) async -> Activity<FeedbackRecordingAttributes>? {
    await Task.detached(priority: .userInitiated) {
      do {
        return try Activity.request(
          attributes: FeedbackRecordingAttributes(),
          content: .init(state: state, staleDate: nil))
      } catch {
        print("[AppFeedback] Live Activity request failed: \(error)")
        return nil
      }
    }.value
  }

  @MainActor
  static func update(_ activity: Activity<FeedbackRecordingAttributes>, screenCount: Int) {
    // `activity.content` is read here at enqueue time, which lags any updates
    // still pending on `queue`. Only immutable fields (like `startedAt`) may
    // be read from it at this point: reading a mutable field (e.g.
    // `screenCount`) here would silently observe pre-queue state and
    // reintroduce the count regression the serial queue exists to prevent.
    let started = activity.content.state.startedAt
    let state = FeedbackRecordingAttributes.ContentState(
      startedAt: started, screenCount: screenCount)
    queue.enqueue { await activity.update(.init(state: state, staleDate: nil)) }
  }

  @MainActor
  static func end(_ activity: Activity<FeedbackRecordingAttributes>) {
    queue.enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
  }

  /// Ends every feedback Live Activity left behind by a PREVIOUS process
  /// (crash/kill mid-recording). The system keeps the activity alive - its
  /// `timerInterval` text keeps counting - but the STOP intent's handler died
  /// with the process, so the banner is a zombie nothing can dismiss. Called
  /// on modifier appear, before any recording of this process starts, so it
  /// can never race a live activity of our own.
  @MainActor
  static func endStale() {
    for activity in Activity<FeedbackRecordingAttributes>.activities {
      queue.enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }
}
#endif
