import Foundation

/// The authoritative clock of one feedback recording session.
///
/// #1393: the cursor's timer used to be derived at RENDER time, as
/// `Date() - capturedDuration` inside a computed property the view body read.
/// `capturedDuration` only advances when a capture segment closes, so every
/// SwiftUI body evaluation pushed the origin forward to "now" and the readout
/// restarted. On a screen that re-renders constantly - A Life Story's call
/// screen updates on every transcript chunk - a recording running for minutes
/// showed a few seconds. The session start lives here instead, is assigned
/// once, and the view only ever reads it.
///
/// Two clocks, deliberately, and they are not interchangeable:
/// - `origin` is WALL time (`Date`), because the cursor's `TimelineView` and
///   the Live Activity both count from a `Date`.
/// - `activeDuration` is MONOTONIC (`ProcessInfo.processInfo.systemUptime`),
///   because it enforces the capture cap and a user changing the device clock
///   must not extend or truncate a recording.
///
/// Pure value type outside the UIKit gate, so the macOS package gate can test
/// every transition with injected instants instead of a real clock.
struct FeedbackRecordingClock: Equatable, Sendable {
  /// Wall instant the session started. Never changes for the life of the
  /// session; also stamped onto the trail's `started_at`.
  let startedAt: Date
  /// What the timer counts from: `startedAt` pushed forward by the time the
  /// session spent paused. Recomputed only on `resume`, never on a read, so a
  /// pause/resume cycle continues the clock rather than restarting it.
  private(set) var origin: Date
  /// Active capture seconds banked by the segments that have already closed.
  private(set) var bankedDuration: TimeInterval
  /// Monotonic uptime the open segment started at; nil while paused.
  private(set) var segmentStartedAt: TimeInterval?

  init(startedAt: Date, uptime: TimeInterval) {
    self.startedAt = startedAt
    self.origin = startedAt
    self.bankedDuration = 0
    self.segmentStartedAt = uptime
  }

  /// True while a ReplayKit segment is open (i.e. not paused).
  var isCapturing: Bool { segmentStartedAt != nil }

  /// Active capture seconds at `uptime`. Paused time is excluded, which is what
  /// preserves the configured cap across any number of resumed segments.
  func activeDuration(uptime: TimeInterval) -> TimeInterval {
    guard let segmentStartedAt else { return bankedDuration }
    return bankedDuration + max(0, uptime - segmentStartedAt)
  }

  /// Closes the open segment and banks its active seconds. Idempotent: a
  /// duplicate lifecycle tick (background + deactivate) cannot double-count.
  mutating func pause(uptime: TimeInterval) {
    guard let segmentStartedAt else { return }
    bankedDuration += max(0, uptime - segmentStartedAt)
    self.segmentStartedAt = nil
  }

  /// Opens the next segment. This is the one place the origin moves, and it
  /// moves by exactly the paused gap - so the displayed timer is continuous
  /// across a background pause without ever crediting the paused seconds.
  /// Idempotent for the same reason `pause` is.
  mutating func resume(uptime: TimeInterval, wall: Date) {
    guard segmentStartedAt == nil else { return }
    origin = wall.addingTimeInterval(-bankedDuration)
    segmentStartedAt = uptime
  }
}
