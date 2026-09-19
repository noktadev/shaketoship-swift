import Foundation
import Testing

@testable import ShakeToShip

/// #1393: the cursor's timer read "0:03" after more than a minute of recording.
///
/// The origin was derived at RENDER time (`Date() - capturedDuration`) and
/// `capturedDuration` only advances when a capture segment closes, so every
/// SwiftUI body evaluation of the host app pushed the origin back to "now". A
/// call screen that re-renders on every transcript update therefore reset the
/// timer several times a second.
///
/// The clock below is the authoritative session start. Its whole contract is
/// that reading it never moves it, so these tests inject every instant instead
/// of touching a real clock.
@Suite struct FeedbackRecordingClockTests {
  private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
  private let bootUptime: TimeInterval = 5_000

  private func clock() -> FeedbackRecordingClock {
    FeedbackRecordingClock(startedAt: start, uptime: bootUptime)
  }

  @Test func theOriginIsTheSessionStart() {
    #expect(clock().origin == start)
    #expect(clock().startedAt == start)
  }

  /// The regression itself: reading the origin repeatedly, at any later instant,
  /// must return the same value. A render-derived origin failed exactly here.
  @Test func readingTheOriginNeverMovesIt() {
    let clock = clock()
    let first = clock.origin
    _ = clock.activeDuration(uptime: bootUptime + 42)
    _ = clock.activeDuration(uptime: bootUptime + 91)
    #expect(clock.origin == first)
  }

  /// The user's report, as an assertion: after 92 seconds the readout says 1:32,
  /// never 0:03.
  @Test func aMinuteAndAHalfOfRecordingReadsAsAMinuteAndAHalf() {
    let clock = clock()
    let now = start.addingTimeInterval(92)
    #expect(FeedbackCursorClock.elapsed(from: clock.origin, to: now) == "1:32")
  }

  @Test func activeDurationCountsTheOpenSegment() {
    let clock = clock()
    #expect(clock.isCapturing)
    #expect(clock.activeDuration(uptime: bootUptime) == 0)
    #expect(clock.activeDuration(uptime: bootUptime + 30) == 30)
  }

  /// A backgrounded app cannot capture, so the banked total freezes at the
  /// pause and the readout must not keep counting.
  @Test func pauseBanksTheSegmentAndFreezesTheTotal() {
    var clock = clock()
    clock.pause(uptime: bootUptime + 30)
    #expect(!clock.isCapturing)
    #expect(clock.bankedDuration == 30)
    #expect(clock.activeDuration(uptime: bootUptime + 300) == 30)
  }

  /// Resuming continues the clock instead of restarting it, and the seconds
  /// spent in the background are never credited to the recording.
  @Test func resumeContinuesTheClockWithoutCreditingThePause() {
    var clock = clock()
    clock.pause(uptime: bootUptime + 30)
    clock.resume(uptime: bootUptime + 100, wall: start.addingTimeInterval(100))
    #expect(clock.isCapturing)
    #expect(clock.activeDuration(uptime: bootUptime + 110) == 40)
    // 30s were captured before the pause, so at wall t=110 the readout is 0:40.
    #expect(
      FeedbackCursorClock.elapsed(from: clock.origin, to: start.addingTimeInterval(110)) == "0:40")
  }

  /// The origin survives a pause/resume as a single stable value, so the resumed
  /// TimelineView does not re-anchor on every render either.
  @Test func theOriginIsStableAcrossAResumedSegment() {
    var clock = clock()
    clock.pause(uptime: bootUptime + 30)
    clock.resume(uptime: bootUptime + 100, wall: start.addingTimeInterval(100))
    let resumedOrigin = clock.origin
    #expect(resumedOrigin == start.addingTimeInterval(70))
    _ = clock.activeDuration(uptime: bootUptime + 400)
    #expect(clock.origin == resumedOrigin)
  }

  @Test func repeatedPausesAndResumesAccumulate() {
    var clock = clock()
    clock.pause(uptime: bootUptime + 10)
    clock.resume(uptime: bootUptime + 60, wall: start.addingTimeInterval(60))
    clock.pause(uptime: bootUptime + 70)
    clock.resume(uptime: bootUptime + 200, wall: start.addingTimeInterval(200))
    #expect(clock.bankedDuration == 20)
    #expect(clock.activeDuration(uptime: bootUptime + 205) == 25)
  }

  /// The cap is monotonic on purpose: a user moving the device clock must not
  /// extend or truncate a capture. `activeDuration` therefore reads uptime, and
  /// only the displayed origin reads wall time.
  @Test func pauseAndResumeAreIdempotentAgainstDuplicateLifecycleTicks() {
    var clock = clock()
    clock.pause(uptime: bootUptime + 30)
    clock.pause(uptime: bootUptime + 90)
    #expect(clock.bankedDuration == 30)
    clock.resume(uptime: bootUptime + 100, wall: start.addingTimeInterval(100))
    clock.resume(uptime: bootUptime + 150, wall: start.addingTimeInterval(150))
    #expect(clock.origin == start.addingTimeInterval(70))
    #expect(clock.activeDuration(uptime: bootUptime + 130) == 60)
  }

  /// systemUptime cannot run backwards, but a stale captured value could still
  /// arrive out of order. A negative segment must never shorten the total.
  @Test func anOutOfOrderUptimeNeverSubtracts() {
    var clock = clock()
    #expect(clock.activeDuration(uptime: bootUptime - 5) == 0)
    clock.pause(uptime: bootUptime - 5)
    #expect(clock.bankedDuration == 0)
  }

  /// What `armCaptureCap` needs after a resume: the remaining allowance, never
  /// negative, computed from banked capture time rather than wall time.
  @Test func theRemainingCapShrinksByCapturedTimeOnly() {
    var clock = clock()
    clock.pause(uptime: bootUptime + 120)
    clock.resume(uptime: bootUptime + 600, wall: start.addingTimeInterval(600))
    #expect(max(0, 180 - clock.bankedDuration) == 60)
    clock.pause(uptime: bootUptime + 700)
    #expect(max(0, 180 - clock.bankedDuration) == 0)
  }
}

/// Source guards for the two render-time mistakes this fix exists to prevent.
/// The modifier is `#if canImport(UIKit)` SwiftUI: no macOS test can render it,
/// so the file itself is read - the same technique
/// `FeedbackRecordingCursorSourceTests` already uses.
@Suite struct ShakeRecorderModifierClockSourceTests {
  private static func source(_ name: String) -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    let file = url.appendingPathComponent("Sources/ShakeToShip/\(name)")
    return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
  }

  @Test func modifierSourceIsReadable() {
    #expect(Self.source("ShakeRecorderModifier.swift").contains("struct ShakeRecorderModifier"))
  }

  /// #1393: `Date().addingTimeInterval(-capturedDuration)` in a computed
  /// property read from `body` is the bug. The origin comes off the clock now.
  @Test func theCursorOriginIsNotDerivedAtRenderTime() {
    let source = Self.source("ShakeRecorderModifier.swift")
    #expect(!source.contains("Date().addingTimeInterval(-capturedDuration)"))
    #expect(source.contains("recordingClock?.origin"))
  }

  /// The view must not own the start instant either - a `@State` start date
  /// assigned in `body` would reset with every identity change of the host.
  @Test func theClockIsTheOnlySourceOfTheSessionStart() {
    let source = Self.source("ShakeRecorderModifier.swift")
    #expect(source.contains("FeedbackRecordingClock("))
    #expect(!source.contains("captureSegmentStartedAt"))
    #expect(!source.contains("capturedDuration"))
  }
}
