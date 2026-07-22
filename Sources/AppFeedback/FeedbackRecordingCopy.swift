/// Shared instructions for narrated feedback capture.
///
/// The recorder enables the microphone as soon as capture starts, so every
/// active surface must tell the user that this is the moment to narrate rather
/// than only confirming that a screen recording exists.
public enum FeedbackRecordingCopy {
  public static let activePrompt = "Speak now - tell us what happened"
  public static let activeAccessibilityLabel =
    "Speak now. Tell us what happened. Feedback is recording. Tap to stop."
  public static let promptExplanation =
    "When recording starts, speak and show us what happened. Shake again or tap stop to finish."
  /// One-time coach mark shown on the first feedback-eligible launch (#584).
  public static let coachMarkMessage = "Shake your phone anytime to record feedback"
}
