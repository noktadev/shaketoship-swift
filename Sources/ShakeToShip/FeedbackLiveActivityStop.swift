import Foundation

/// App-process bridge from the Live Activity STOP button to the recorder
/// modifier. `StopFeedbackIntent.perform()` runs in the APP process and calls
/// `signal()`; the modifier registers a MainActor handler while recording that
/// runs the normal stop path. Platform-neutral (no ActivityKit) so it is unit
/// testable and so the wiring compiles on every target.
@MainActor
public enum FeedbackLiveActivityStop {
  private static var handler: (@MainActor () async -> Void)?

  /// Modifier registers on record start. The handler is `async` so
  /// `StopFeedbackIntent.perform()` can AWAIT the whole stop path: perform()
  /// returning early would let the OS suspend the backgrounded app before
  /// finalize, leaving capture rolling and the writer unfinalized.
  public static func register(_ handler: @escaping @MainActor () async -> Void) {
    self.handler = handler
  }

  /// Modifier unregisters on stop so a stale closure cannot fire into a
  /// finished recording.
  public static func unregister() {
    handler = nil
  }

  /// Called by `StopFeedbackIntent.perform()`. Returns only once the stop path
  /// has finished (finalize-to-outbox at minimum). No-op when nothing is
  /// recording.
  public static func signal() async {
    await handler?()
  }
}
