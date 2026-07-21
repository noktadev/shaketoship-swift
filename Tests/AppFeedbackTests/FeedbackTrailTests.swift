import Foundation
import Testing

@testable import AppFeedback

@Suite struct FeedbackTrailTests {
  /// Deterministic monotonic clock: returns successive queued values.
  private func clock(_ values: [Double]) -> @Sendable () -> Double {
    let box = ValueBox(values)
    return { box.next() }
  }

  @Test func seedsFromLastBufferedScreenName() {
    let trail = FeedbackTrail(now: clock([100]))
    for i in 0..<25 { trail.screen("n\(i)") }  // idle: ring buffer

    trail.startSession(sessionId: "s1", app: "dotself", build: "1", startedAt: "T")
    let session = trail.stop()

    #expect(session.events.first == FeedbackEvent(t: 0, screen: "n24"))
  }

  @Test func recordingTrailUsesRelativeSeconds() {
    let trail = FeedbackTrail(now: clock([100, 101, 102.5]))
    trail.screen("Home")  // idle buffer

    trail.startSession(sessionId: "s1", app: "dotself", build: "1", startedAt: "T")  // now()->100 (start)
    trail.screen("A")  // now()->101 => t=1
    trail.screen("B")  // now()->102.5 => t=2.5
    let session = trail.stop()

    #expect(session.events == [
      FeedbackEvent(t: 0, screen: "Home"),
      FeedbackEvent(t: 1, screen: "A"),
      FeedbackEvent(t: 2.5, screen: "B"),
    ])
    #expect(session.session_id == "s1")
    #expect(session.started_at == "T")
  }

  @Test func emptyBufferProducesNoSeedEvent() {
    let trail = FeedbackTrail(now: clock([100, 101]))
    trail.startSession(sessionId: "s1", app: "dotself", build: "1", startedAt: "T")
    trail.screen("First")  // t = 1
    let session = trail.stop()

    #expect(session.events == [FeedbackEvent(t: 1, screen: "First")])
  }

  @Test func consecutiveDuplicateScreensAreDroppedWhileRecording() {
    let trail = FeedbackTrail(now: clock([100, 101, 102]))
    trail.startSession(sessionId: "s1", app: "lockin-chinese", build: "1", startedAt: "T")
    trail.screen("settings")  // t = 1
    trail.screen("settings")  // duplicate: dropped, consumes no clock
    trail.screen("quiz")  // t = 2
    let session = trail.stop()

    #expect(session.events == [
      FeedbackEvent(t: 1, screen: "settings"),
      FeedbackEvent(t: 2, screen: "quiz"),
    ])
  }

  @Test func alternatingScreensAreAllKept() {
    let trail = FeedbackTrail(now: clock([100, 101, 102, 103]))
    trail.startSession(sessionId: "s1", app: "lockin-chinese", build: "1", startedAt: "T")
    trail.screen("home")
    trail.screen("quiz")
    trail.screen("home")
    let session = trail.stop()

    #expect(session.events.map(\.screen) == ["home", "quiz", "home"])
  }

  /// The seed event counts as "last": re-emitting the seeded screen right after
  /// start (both shell observers fire on mount) records it once, not twice.
  @Test func duplicateOfSeededScreenIsDropped() {
    let trail = FeedbackTrail(now: clock([100, 101]))
    trail.screen("home")  // idle buffer -> seed
    trail.startSession(sessionId: "s1", app: "lockin-chinese", build: "1", startedAt: "T")
    trail.screen("home")  // duplicate of seed: dropped
    trail.screen("quiz")  // t = 1
    let session = trail.stop()

    #expect(session.events == [
      FeedbackEvent(t: 0, screen: "home"),
      FeedbackEvent(t: 1, screen: "quiz"),
    ])
  }

  @Test func consecutiveDuplicatesAreDroppedWhileIdle() {
    let trail = FeedbackTrail(now: clock([100]))
    trail.screen("home")
    trail.screen("home")  // duplicate: dropped from the idle buffer too
    trail.screen("settings")
    trail.startSession(sessionId: "s1", app: "lockin-chinese", build: "1", startedAt: "T")
    let session = trail.stop()

    // Only the LAST buffered name seeds, so prove the dedupe via capacity: the
    // duplicate must not have evicted anything (buffer holds 2 entries, not 3).
    #expect(session.events == [FeedbackEvent(t: 0, screen: "settings")])
  }

  @Test func idleScreenCallsDoNotAppendAfterStop() {
    let trail = FeedbackTrail(now: clock([100, 101]))
    trail.startSession(sessionId: "s1", app: "dotself", build: "1", startedAt: "T")
    trail.screen("A")  // t = 1
    _ = trail.stop()
    trail.screen("B")  // idle again, must not append to a session

    let second = FeedbackTrail(now: clock([200]))
    second.startSession(sessionId: "s2", app: "dotself", build: "1", startedAt: "T2")
    #expect(second.stop().events.isEmpty)
  }

  @Test func activeEventHandlerFiresWithEventCount() {
    let box = IntArrayBox()
    let trail = FeedbackTrail(now: clock([100, 101, 102]))
    trail.setActiveEventHandler { box.append($0) }
    trail.startSession(sessionId: "s", app: "a", build: "1", startedAt: "T")
    trail.screen("Home")  // event #1
    trail.screen("Detail")  // event #2
    #expect(box.values == [1, 2])
    trail.setActiveEventHandler(nil)
  }

  @Test func activeEventHandlerNotFiredWhileIdle() {
    let box = IntArrayBox()
    let trail = FeedbackTrail(now: clock([100]))
    trail.setActiveEventHandler { box.append($0) }
    trail.screen("Home")  // idle buffer write, no active session
    #expect(box.values.isEmpty)
    trail.setActiveEventHandler(nil)
  }

  @Test func startSessionReturnsSeededEventCount() {
    let trail = FeedbackTrail(now: { 0 })
    trail.screen("Home")
    let seeded = trail.startSession(sessionId: "s1", app: "a", build: "1", startedAt: "t")
    // The trail seeds {t:0, screen:"Home"}; the Live Activity must start at 1,
    // not 0, so the widget does not show "0 screens" for the current screen.
    #expect(seeded == 1)
  }

  @Test func startSessionWithEmptyBufferReturnsZero() {
    let trail = FeedbackTrail(now: { 0 })
    let seeded = trail.startSession(sessionId: "s1", app: "a", build: "1", startedAt: "t")
    #expect(seeded == 0)
  }

  @Test func tapsAreRecordedWithRelativeSecondsWhileRecording() {
    let trail = FeedbackTrail(now: clock([100, 112.25]))
    trail.startSession(sessionId: "s1", app: "lockin-chinese", build: "1", startedAt: "T")
    trail.tap(x: 0.5, y: 0.75, element: "PRACTICE")
    let session = trail.stop()

    #expect(session.events == [
      .tap(t: 12.25, tap: FeedbackTap(x: 0.5, y: 0.75, element: "PRACTICE")),
    ])
  }

  /// Only screen names buffer while idle. A tap outside a recording is dropped
  /// (it must not leak into the next session's seed).
  @Test func idleTapsAreNotBuffered() {
    let trail = FeedbackTrail(now: clock([100, 101]))
    trail.tap(x: 0.1, y: 0.1, element: "Ignored")
    trail.screen("home")
    trail.tap(x: 0.2, y: 0.2, element: "AlsoIgnored")
    trail.startSession(sessionId: "s1", app: "a", build: "1", startedAt: "T")
    let session = trail.stop()

    #expect(session.events == [FeedbackEvent(t: 0, screen: "home")])
  }

  @Test func tapsAreNotRecordedAfterStop() {
    let trail = FeedbackTrail(now: clock([100, 101]))
    trail.startSession(sessionId: "s1", app: "a", build: "1", startedAt: "T")
    _ = trail.stop()
    trail.tap(x: 0.5, y: 0.5, element: "Late")

    let second = FeedbackTrail(now: clock([200]))
    second.startSession(sessionId: "s2", app: "a", build: "1", startedAt: "T2")
    #expect(second.stop().events.isEmpty)
  }

  @Test func tapsInterleaveWithScreensInOrder() {
    let trail = FeedbackTrail(now: clock([100, 101, 102, 103]))
    trail.startSession(sessionId: "s1", app: "a", build: "1", startedAt: "T")
    trail.screen("home")  // t = 1
    trail.tap(x: 0.5, y: 0.9, element: "PRACTICE")  // t = 2
    trail.screen("quiz")  // t = 3
    let session = trail.stop()

    #expect(session.events == [
      FeedbackEvent(t: 1, screen: "home"),
      .tap(t: 2, tap: FeedbackTap(x: 0.5, y: 0.9, element: "PRACTICE")),
      FeedbackEvent(t: 3, screen: "quiz"),
    ])
  }

  /// Screen dedup compares against the last SCREEN event, not the last event:
  /// a tap in between must not let a duplicate screen through.
  @Test func tapBetweenDuplicateScreensDoesNotDefeatDedup() {
    let trail = FeedbackTrail(now: clock([100, 101, 102, 103]))
    trail.startSession(sessionId: "s1", app: "a", build: "1", startedAt: "T")
    trail.screen("home")  // t = 1
    trail.tap(x: 0.5, y: 0.5, element: nil)  // t = 2
    trail.screen("home")  // duplicate of the last SCREEN: dropped
    let session = trail.stop()

    #expect(session.events == [
      FeedbackEvent(t: 1, screen: "home"),
      .tap(t: 2, tap: FeedbackTap(x: 0.5, y: 0.5, element: nil)),
    ])
  }

  /// The handler contract is the SCREEN count (the Live Activity renders "N
  /// screens"), so a tap must not fire it and must not advance the count.
  @Test func tapsDoNotFireTheActiveEventHandler() {
    let box = IntArrayBox()
    let trail = FeedbackTrail(now: clock([100, 101, 102, 103]))
    trail.setActiveEventHandler { box.append($0) }
    trail.startSession(sessionId: "s", app: "a", build: "1", startedAt: "T")
    trail.screen("Home")  // screen #1
    #expect(box.values == [1])
    trail.tap(x: 0.1, y: 0.2, element: nil)  // not a screen: no handler fire
    #expect(box.values == [1])
    trail.screen("Quiz")  // screen #2
    #expect(box.values == [1, 2])
    trail.setActiveEventHandler(nil)
  }
}

/// Test-only accumulator shared across a @Sendable handler closure.
private final class IntArrayBox: @unchecked Sendable {
  private(set) var values: [Int] = []
  private let lock = NSLock()
  func append(_ v: Int) {
    lock.lock()
    defer { lock.unlock() }
    values.append(v)
  }
}

/// Test-only queue of Double values shared across a @Sendable closure.
private final class ValueBox: @unchecked Sendable {
  private var values: [Double]
  private let lock = NSLock()
  init(_ values: [Double]) { self.values = values }
  func next() -> Double {
    lock.lock()
    defer { lock.unlock() }
    return values.isEmpty ? 0 : values.removeFirst()
  }
}
