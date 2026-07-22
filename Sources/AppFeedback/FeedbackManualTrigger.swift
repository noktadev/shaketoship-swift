import Foundation

/// App-process bridge from a non-shake entry point (Settings' "Send feedback
/// now" row) into `ShakeRecorderModifier`'s existing shake-handling path.
/// Registering here and calling through `handleShake()` guarantees the manual
/// entry point observes the exact same cooldown/rate-cap/busy suppression a
/// physical shake does (see `FeedbackPromptGate`) - there is no separate,
/// divergent "start recording" code path to keep in sync.
@MainActor
public enum FeedbackManualTrigger {
  private static var handler: (@MainActor () -> Void)?

  /// The modifier registers this while mounted (recorder active at all).
  public static func register(_ handler: @escaping @MainActor () -> Void) {
    self.handler = handler
  }

  /// The modifier unregisters on teardown so a stale closure cannot fire.
  public static func unregister() {
    handler = nil
  }

  /// Called by the manual entry point (e.g. a Settings row). No-op when
  /// nothing is mounted (recorder inert - App Store, or gate off).
  public static func signal() {
    handler?()
  }
}
