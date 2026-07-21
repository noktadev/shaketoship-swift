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
  @MainActor
  static func start(
    startedAt: Date,
    screenCount: Int,
    onFailure: (FeedbackLiveActivityStartFailure) -> Void = { _ in }
  ) -> Activity<FeedbackRecordingAttributes>? {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      onFailure(.activitiesDisabled)
      return nil
    }
    let state = FeedbackRecordingAttributes.ContentState(
      startedAt: startedAt, screenCount: screenCount)
    do {
      return try Activity.request(
        attributes: FeedbackRecordingAttributes(),
        content: .init(state: state, staleDate: nil))
    } catch {
      // The concrete error is deliberately not forwarded: it reaches analytics,
      // and ActivityKit's localized strings are user/locale text, not wire data.
      print("[AppFeedback] Live Activity request failed: \(error)")
      onFailure(.requestFailed)
      return nil
    }
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
