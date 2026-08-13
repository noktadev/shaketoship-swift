import Foundation

/// Funnel signals the recorder emits at the obvious flow points. The package
/// stays zero-dependency and never talks to AppAnalytics directly (it is linked
/// into an extension, which must never emit); the host app maps these onto its
/// own analytics client via `ShakeToShipConfig.onFunnelEvent`. A nil callback = no
/// emission, so the Widgets extension - which never constructs a config - cannot
/// emit by construction.
public enum FeedbackFunnelEvent: Sendable, Equatable {
  /// The "Something wrong?" prompt was surfaced.
  case promptShown
  /// The prompt was dismissed with "Not now".
  case promptDismissed
  /// Recording actually started (after ReplayKit consent).
  case recordingStarted
  /// Recording finalized. `reason` is `user` | `cap` | `interruption`.
  case recordingStopped(durationSeconds: Double, reason: String)
  /// Review sheet "Upload" tapped.
  case reviewUploaded
  /// Review sheet "Discard" tapped.
  case reviewDiscarded
  /// Upload attempt resolved. `outcome` is `uploaded` | `queued` | `unqueued`.
  case uploadResult(outcome: String)
  /// Diagnostic: a durable outbox-marker operation ultimately failed after its
  /// retries (#472). `operation` is `interrupted-write` | `interrupted-clear`.
  /// Surfaced so a persistent disk problem is observable instead of silently
  /// stranding or re-offering a session; never blocks the fail-safe behaviour.
  case markerFailure(operation: String)
  /// Diagnostic: the recording started but its Live Activity did not appear
  /// (#557). `reason` is a `FeedbackLiveActivityStartFailure` raw value:
  /// `activities-disabled` | `request-failed`. Both modes previously resolved to
  /// a silent nil, leaving "the live activity thing is not visible for me"
  /// undiagnosable from the outside. Never blocks recording - the Live Activity
  /// is an affordance, not the capture itself.
  case liveActivityStartFailed(reason: String)
}
