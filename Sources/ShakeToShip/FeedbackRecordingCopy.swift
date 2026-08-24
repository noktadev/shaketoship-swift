/// Shared instructions for narrated feedback capture.
///
/// The recorder enables the microphone as soon as capture starts, so every
/// active surface must tell the user that this is the moment to narrate rather
/// than only confirming that a screen recording exists.
public enum FeedbackRecordingCopy {
  public static let activePrompt = "Speak now - tell us what happened"
  static let activeAccessibilityLabel =
    "Speak now. Tell us what happened. Feedback is recording. Tap to stop."
  static let promptExplanation =
    "When recording starts, speak and show us what happened. Shake again or tap stop to finish."
  /// One-time coach mark shown on the first feedback-eligible launch (#584).
  public static let coachMarkMessage = "Shake your phone anytime to record feedback"
  /// Transient hint (#1092) shown the moment a recording starts: a user who
  /// shakes to start has no other cue that shaking again is how they stop.
  static let shakeAgainToStopHint = "Shake again to stop."
  static let shakeAgainToStopAccessibilityLabel = "Shake again to stop the recording."

  /// Recording cursor. Icon-only controls, so these strings exist for VoiceOver
  /// rather than for display - the one exception is `pausedLabel`, which reads
  /// in place of the timer.
  static let pausedLabel = "Paused"
  static let pauseAction = "Pause recording"
  static let resumeAction = "Resume recording"
  static let stopAction = "Stop and review"
  static let muteAction = "Mute microphone"
  static let unmuteAction = "Unmute microphone"
  /// Shown once on the first recording: a draggable cursor is not a discoverable
  /// affordance on its own.
  static let cursorHint = "Drag to point. Double tap for controls."
}
