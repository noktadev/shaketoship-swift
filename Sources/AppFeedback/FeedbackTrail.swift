import Foundation

/// Tracks screen navigation so a recording can be annotated with a screen
/// trail. When idle it keeps a ring buffer of the last `bufferCapacity` screen
/// names; while recording it appends timestamped events relative to the
/// recording start.
///
/// This is the testable core behind the `Feedback` facade. Time is injectable
/// via `now` (monotonic seconds) so trail behavior is deterministic in tests.
public final class FeedbackTrail: @unchecked Sendable {
  static let bufferCapacity = 20

  private let now: @Sendable () -> Double
  private let lock = NSLock()

  // Idle state.
  private var buffer: [String] = []

  // Recording state (nil when idle).
  private var active: Active?

  // Fired (outside the lock) with the active-session SCREEN count whenever a
  // new screen event is appended while recording. The modifier uses it to
  // update the Live Activity screen count. Never fired for taps or
  // idle-buffer writes.
  private var onActiveEvent: (@Sendable (Int) -> Void)?

  private struct Active {
    let sessionId: String
    let app: String
    let build: String
    let startedAt: String
    let start: Double
    var events: [FeedbackEvent]
  }

  /// `now` defaults to a monotonic clock (`systemUptime`) so an NTP/wall-clock
  /// jump mid-recording cannot corrupt event `t` values. Tests inject their own.
  public init(now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
    self.now = now
  }

  /// Called by apps on navigation changes.
  ///
  /// Consecutive identical names are dropped here - once, for every emission
  /// seam - so overlapping observers (e.g. a nav path and a sheet flag that
  /// both mutate on one transition, or a root seam handing off to a shell
  /// seam) cannot double-record the same screen.
  public func screen(_ name: String) {
    lock.lock()
    var notify: Int?
    if active != nil {
      if active!.events.last(where: { $0.screen != nil })?.screen != name {
        let t = now() - active!.start
        active!.events.append(FeedbackEvent(t: t, screen: name))
        notify = active!.events.count(where: { $0.screen != nil })
      }
    } else {
      if buffer.last != name {
        buffer.append(name)
        if buffer.count > Self.bufferCapacity {
          buffer.removeFirst(buffer.count - Self.bufferCapacity)
        }
      }
    }
    // Never call the user closure under `lock`: capture it, release, then fire.
    let handler = onActiveEvent
    lock.unlock()
    if let notify, let handler { handler(notify) }
  }

  /// Called by the tap recognizer the recorder installs while recording.
  ///
  /// Taps are session-only: unlike screen names there is no idle buffer, so a
  /// tap outside a recording is dropped rather than leaking into the next
  /// session's seed. `x`/`y` are already normalized (see `FeedbackTapFormatting`).
  public func tap(x: Double, y: Double, element: String?) {
    lock.lock()
    if active != nil {
      let t = now() - active!.start
      active!.events.append(.tap(t: t, tap: FeedbackTap(x: x, y: y, element: element)))
    }
    lock.unlock()
  }

  /// Registers a handler invoked with the current active-session event count on
  /// each new recorded event. Pass `nil` to clear. Thread-safe. One call per new
  /// event (the modifier relies on this: at most one Live Activity update per
  /// screen change).
  public func setActiveEventHandler(_ handler: (@Sendable (Int) -> Void)?) {
    lock.lock()
    onActiveEvent = handler
    lock.unlock()
  }

  /// Begins a recording session. Seeds a `{t: 0, screen: <last buffered name>}`
  /// event when a buffered name exists. Returns the seeded event count so the
  /// caller can start the Live Activity at the real screen count.
  @discardableResult
  public func startSession(sessionId: String, app: String, build: String, startedAt: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    let start = now()
    var seeded: [FeedbackEvent] = []
    if let last = buffer.last {
      seeded.append(FeedbackEvent(t: 0, screen: last))
    }
    active = Active(
      sessionId: sessionId, app: app, build: build, startedAt: startedAt,
      start: start, events: seeded)
    buffer.removeAll()
    return seeded.count
  }

  /// Ends the recording and returns the assembled session. Returns an empty
  /// session if called with no active recording.
  @discardableResult
  public func stop() -> FeedbackSession {
    lock.lock()
    defer { lock.unlock() }
    guard let a = active else {
      return FeedbackSession(session_id: "", app: "", build: "", started_at: "", events: [])
    }
    active = nil
    return FeedbackSession(
      session_id: a.sessionId, app: a.app, build: a.build,
      started_at: a.startedAt, events: a.events)
  }
}

/// Static facade apps call on navigation changes: `Feedback.screen("Home")`.
public enum Feedback {
  public static let shared = FeedbackTrail()

  public static func screen(_ name: String) {
    shared.screen(name)
  }

  public static func tap(x: Double, y: Double, element: String?) {
    shared.tap(x: x, y: y, element: element)
  }
}
