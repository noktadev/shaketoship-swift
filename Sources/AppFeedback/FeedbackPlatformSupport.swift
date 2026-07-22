import Foundation

/// Whether this build target can actually run the shake-to-record recorder.
/// Mirrors the compile-time gate `feedbackRecorder(config:)` no-ops behind:
/// false on the Simulator (ReplayKit is non-functional there) and Mac
/// Catalyst (hostless kit test runner only, never a shipping surface).
///
/// Extracted as its own pure surface (same pattern as
/// `FeedbackBuildChannel.current`) so a caller's own eligibility decision -
/// the coach mark, the manual "Send feedback now" row - can factor in
/// "the recorder would actually attach here" instead of drifting from the
/// modifier's own no-op gate. Without this, a configured DEBUG simulator has
/// a non-nil `activeConfig` but zero real recorder: the coach mark burned its
/// one-time flag telling a tester to shake with nothing listening, and the
/// manual row rendered with no handler wired up.
public enum FeedbackPlatformSupport {
  public static var isRecorderSupported: Bool {
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    return false
    #else
    return true
    #endif
  }
}
