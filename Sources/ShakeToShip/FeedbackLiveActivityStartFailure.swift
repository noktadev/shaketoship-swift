import Foundation

/// Why a Live Activity start produced no visible activity (#557).
///
/// Platform-neutral (no ActivityKit) so it is unit testable and compiles on every
/// target, matching `FeedbackLiveActivityStop`. The controller that produces
/// these values is device-only, so this vocabulary is the whole observable
/// surface of the start path.
///
/// Raw values are analytics wire strings - see the funnel event that carries them.
public enum FeedbackLiveActivityStartFailure: String, Sendable, Equatable, CaseIterable {
  /// `ActivityAuthorizationInfo().areActivitiesEnabled` was false: the user has
  /// Live Activities switched off for this app (Settings > <app> > Live
  /// Activities, or the system-wide toggle). Nothing the app can do about it -
  /// but it is the difference between "we are broken" and "it is off".
  case activitiesDisabled = "activities-disabled"
  /// `Activity.request` threw: activity budget exhausted, the widget extension
  /// has no matching `ActivityConfiguration`, or ActivityKit refused it.
  case requestFailed = "request-failed"
}
