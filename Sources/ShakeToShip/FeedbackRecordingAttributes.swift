// ActivityKit's types are `canImport` true on macOS/Mac Catalyst but
// `unavailable` on both, so guard on `os(iOS) && !macCatalyst` (not `canImport`)
// - the whole Live Activity surface is iOS-device/simulator only. Neither the
// macOS host `swift test` build nor the Mac Catalyst DotselfKit test build
// (where `os(iOS)` is true) ever sees this file.
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents
import Foundation

/// Shared Live Activity type for the DEBUG feedback recorder. Defined in
/// ShakeToShip so the app (which starts/updates/ends the activity) and the
/// widget extension (which renders it) reference ONE type.
public struct FeedbackRecordingAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable, Sendable {
    /// Recording start; the widget renders elapsed time via `Text(timerInterval:)`.
    public var startedAt: Date
    /// Number of screen-trail events captured so far.
    public var screenCount: Int

    public init(startedAt: Date, screenCount: Int) {
      self.startedAt = startedAt
      self.screenCount = screenCount
    }
  }

  public init() {}
}

/// STOP button intent for the Live Activity. As a `LiveActivityIntent` it runs
/// in the APP process, so it can reach the in-process stop registry directly
/// (no notifications-to-extension). Defined in ShakeToShip so the widget's
/// `Button(intent:)` and the app share one type.
@available(iOS 17.0, *)
public struct StopFeedbackIntent: LiveActivityIntent {
  public static let title: LocalizedStringResource = "Stop Recording"
  public init() {}

  public func perform() async throws -> some IntentResult {
    await FeedbackLiveActivityStop.signal()
    return .result()
  }
}
#endif
