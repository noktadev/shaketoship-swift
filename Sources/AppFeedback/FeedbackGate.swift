import Foundation

/// Pure runtime-gate decisions for the feedback recorder. Kept dependency-free
/// and UIKit-free so the "provably inert when off" and "don't nag" rules are
/// unit-tested without a live responder chain or recorder, exactly like
/// `FeedbackTapFormatting`.
public enum FeedbackGate {
  /// Whether `.feedbackRecorder(config:)` installs the recorder at all. A nil
  /// config is the inertness proof: no shake responder, no review window, no
  /// recorder is ever constructed. The per-app resolver decides the config is
  /// nil unless (DEBUG) or (remoteFlag && rolloutBucket && settingsOptIn).
  public static func shouldAttach(config: FeedbackConfig?) -> Bool {
    config != nil
  }
}

/// What an idle/active shake should do, once suppression is accounted for.
public enum FeedbackShakeAction: Equatable {
  /// Suppressed - busy, mid-review, past the rate cap, or inside the cooldown.
  case ignore
  /// Already recording: a shake stops it.
  case stopRecording
  /// Idle and allowed: surface the "Something wrong?" prompt.
  case showPrompt
}

/// Decides whether a shake surfaces the prompt. The cooldown stops a
/// walking-with-phone nag loop after a "Not now"; the rate cap goes silent
/// after `maxPromptsPerSession` dismissals until the next launch.
public enum FeedbackPromptGate {
  /// After a "Not now", ignore shakes for this long.
  public static let cooldownSeconds: TimeInterval = 60
  /// Max prompts surfaced per app session; silent afterwards.
  public static let maxPromptsPerSession = 3

  /// - Parameters:
  ///   - now / lastDismissedAt: seconds on any monotonic-ish clock; only their
  ///     difference matters, so the caller can pass `Date().timeIntervalSince1970`
  ///     or `ProcessInfo.systemUptime` as long as it is consistent.
  public static func action(
    isRecording: Bool,
    busy: Bool,
    reviewPresenting: Bool,
    promptPresenting: Bool,
    promptsShown: Int,
    lastDismissedAt: TimeInterval?,
    now: TimeInterval
  ) -> FeedbackShakeAction {
    if isRecording { return .stopRecording }
    // A shake while the prompt is already up must not re-count or re-emit -
    // otherwise a couple of shakes burn the whole per-session cap instantly.
    if busy || reviewPresenting || promptPresenting { return .ignore }
    if promptsShown >= maxPromptsPerSession { return .ignore }
    if let lastDismissedAt, now - lastDismissedAt < cooldownSeconds { return .ignore }
    return .showPrompt
  }
}
