import CoreGraphics
import Foundation
import Testing

@testable import ShakeToShip

/// The cursor view is `#if canImport(UIKit)` SwiftUI and cannot be rendered or
/// measured in a macOS test. Everything worth pinning was therefore pulled out
/// as pure maths, and the layout constraint that cannot be is guarded by reading
/// the source.
///
/// This split exists because of what shipped: a full-screen blur (#1183) and a
/// control behind the status bar (#1184), neither visible to any gate short of a
/// device build.
@Suite struct FeedbackInkFadeTests {
  @Test func inkHoldsAtFullStrengthThroughTheHoldWindow() {
    #expect(FeedbackInkFade.life(age: 0) == 1)
    #expect(FeedbackInkFade.life(age: FeedbackInkFade.hold) == 1)
  }

  /// The reason `hold` exists: a linear fade from t=0 was already invisible by
  /// the halfway mark, so a nominal six seconds read as about three.
  @Test func inkIsStillClearlyVisibleAtTheMidpoint() {
    let mid = FeedbackInkFade.lifetime / 2
    #expect(FeedbackInkFade.life(age: mid) > 0.9)
  }

  @Test func inkIsGoneByTheEndOfItsLifetime() {
    #expect(FeedbackInkFade.life(age: FeedbackInkFade.lifetime) == 0)
    #expect(FeedbackInkFade.life(age: FeedbackInkFade.lifetime + 5) == 0)
  }

  @Test func fadeIsMonotonicAfterTheHold() {
    var previous = 1.0
    var age = FeedbackInkFade.hold
    while age <= FeedbackInkFade.lifetime {
      let life = FeedbackInkFade.life(age: age)
      #expect(life <= previous)
      previous = life
      age += 0.2
    }
  }

  @Test func noDismissalMeansFullStrength() {
    #expect(FeedbackInkFade.dismissFactor(now: 1000, dismissedAt: nil) == 1)
  }

  @Test func dismissalReachesZeroWithinItsDuration() {
    let now = 1000.0
    #expect(FeedbackInkFade.dismissFactor(now: now, dismissedAt: now) == 1)
    #expect(
      FeedbackInkFade.dismissFactor(
        now: now + FeedbackInkFade.dismissDuration, dismissedAt: now) == 0)
    #expect(FeedbackInkFade.dismissFactor(now: now + 10, dismissedAt: now) == 0)
  }

  @Test func prunedDropsOnlyFullyFadedStrokes() {
    let now = 1000.0
    let stale = [FeedbackInkPoint(x: 0, y: 0, t: now - FeedbackInkFade.lifetime - 1)]
    let fresh = [FeedbackInkPoint(x: 1, y: 1, t: now - 1)]
    let kept = FeedbackInkBuffer.pruned([stale, fresh], now: now)
    #expect(kept.count == 1)
    #expect(kept.first?.first?.x == 1)
  }
}

@Suite struct FeedbackCursorGeometryTests {
  private let screen = CGSize(width: 402, height: 874)
  private let safeTop: CGFloat = 59
  private let safeBottom: CGFloat = 34

  /// #1184: the bar sat behind the clock and battery. The nib must never be able
  /// to land in the status-bar strip.
  @Test func nibCannotLandBehindTheStatusBar() {
    let clamped = FeedbackCursorGeometry.clamp(
      CGPoint(x: 200, y: -500), in: screen, safeTop: safeTop, safeBottom: safeBottom)
    #expect(clamped.y >= safeTop)
  }

  @Test func nibCannotLandUnderTheHomeIndicator() {
    let clamped = FeedbackCursorGeometry.clamp(
      CGPoint(x: 200, y: 5000), in: screen, safeTop: safeTop, safeBottom: safeBottom)
    #expect(clamped.y <= screen.height - safeBottom)
  }

  /// The label hangs off the nib to the trailing side, so a nib parked at the
  /// right edge would push its own controls off screen.
  @Test func labelAlwaysHasRoomOnScreen() {
    let clamped = FeedbackCursorGeometry.clamp(
      CGPoint(x: 5000, y: 400), in: screen, safeTop: safeTop, safeBottom: safeBottom)
    #expect(clamped.x + FeedbackCursorGeometry.labelReserve <= screen.width)
  }

  @Test func nibStaysReachableFromTheLeadingEdge() {
    let clamped = FeedbackCursorGeometry.clamp(
      CGPoint(x: -900, y: 400), in: screen, safeTop: safeTop, safeBottom: safeBottom)
    #expect(clamped.x >= 0)
    #expect(clamped.x <= 20)  // close enough to point at leading-edge content
  }

  @Test func clampIsIdempotent() {
    let once = FeedbackCursorGeometry.clamp(
      CGPoint(x: 9000, y: 9000), in: screen, safeTop: safeTop, safeBottom: safeBottom)
    let twice = FeedbackCursorGeometry.clamp(
      once, in: screen, safeTop: safeTop, safeBottom: safeBottom)
    #expect(once == twice)
  }

  /// A tiny screen must still produce a point inside itself rather than an
  /// inverted range.
  @Test func absurdlySmallScreenStillYieldsAPointInside() {
    let tiny = CGSize(width: 60, height: 80)
    let clamped = FeedbackCursorGeometry.clamp(
      CGPoint(x: 30, y: 40), in: tiny, safeTop: 20, safeBottom: 20)
    #expect(clamped.x >= 0 && clamped.x <= tiny.width)
    #expect(clamped.y >= 0 && clamped.y <= tiny.height)
  }

  @Test func homeSitsAboveTheMidline() {
    #expect(FeedbackCursorGeometry.home(in: screen).y < screen.height / 2)
  }

  /// A touch-down that is really the start of a drag must not be read as a
  /// background tap, or grabbing the cursor would wipe the ink.
  @Test func hitBoxCoversAtLeastAMinimumTarget() {
    let box = FeedbackCursorGeometry.hitBox(nib: CGPoint(x: 100, y: 100), measured: .zero)
    #expect(box.width >= 44)
    #expect(box.height >= 34)
    #expect(box.contains(CGPoint(x: 100, y: 100)))
  }
}

/// Source guard: the layout invariants that broke on device and that no macOS
/// test can observe.
@Suite struct FeedbackRecordingCursorSourceTests {
  private static func source(_ name: String) -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    let file = url.appendingPathComponent("Sources/ShakeToShip/\(name)")
    return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
  }

  @Test func cursorSourceIsReadable() {
    #expect(Self.source("FeedbackRecordingCursor.swift").contains("struct FeedbackRecordingCursor"))
  }

  /// #1183: the bar's greedy hit areas made its material cover the whole screen.
  /// The cursor must never ask for infinite height.
  @Test func cursorNeverRequestsGreedyHeight() {
    #expect(!Self.source("FeedbackRecordingCursor.swift").contains("maxHeight: .infinity"))
  }

  /// The ink must stay inert. If this constraint is ever dropped, the trail
  /// starts eating the host app's touches.
  @Test func inkTrailIsNotHitTestable() {
    #expect(Self.source("FeedbackInkTrail.swift").contains(".allowsHitTesting(false)"))
  }

  /// The observer reports touches and declines them. `return false` from
  /// `shouldReceive` is what keeps the host app's taps working.
  @Test func touchObserverDeclinesEveryTouch() {
    let source = Self.source("FeedbackInkTrail.swift")
    #expect(source.contains("cancelsTouchesInView = false"))
    #expect(source.contains("return false"))
  }

  /// A stationary tap must reach the tap recogniser, or the expansion can never
  /// open - `minimumDistance: 0` swallowed it during the lab build.
  @Test func dragDoesNotSwallowTheTap() {
    let source = Self.source("FeedbackRecordingCursor.swift")
    #expect(!source.contains("DragGesture(minimumDistance: 0)"))
    #expect(source.contains("onTapGesture(count: 2)"))
  }

  /// CLOCK RULE: inside a TimelineView, read the tick off `timeline.date`. A
  /// second clock skews phase against the ink canvas.
  @Test func cursorTimerReadsTheTimelineClock() {
    #expect(Self.source("FeedbackRecordingCursor.swift").contains("to: timeline.date"))
  }

  /// The bar carried a mid-recording microphone mute. Losing a privacy control
  /// in a redesign is the kind of regression nobody notices until it matters.
  @Test func microphoneMuteSurvivedTheRedesign() {
    let source = Self.source("FeedbackRecordingCursor.swift")
    #expect(source.contains("microphoneAllowed"))
    #expect(source.contains("FeedbackMicrophonePreference"))
  }
}

@Suite struct FeedbackRecordingCursorClockTests {
  @Test func elapsedFormatsMinutesAndSeconds() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    #expect(
      FeedbackCursorClock.elapsed(from: start, to: start.addingTimeInterval(0)) == "0:00")
    #expect(
      FeedbackCursorClock.elapsed(from: start, to: start.addingTimeInterval(61)) == "1:01")
    #expect(
      FeedbackCursorClock.elapsed(from: start, to: start.addingTimeInterval(599)) == "9:59")
  }

  /// A resumed session recomputes its origin from accumulated capture time, so a
  /// clock skew must never render as a negative timer.
  @Test func elapsedNeverGoesNegative() {
    let start = Date(timeIntervalSinceReferenceDate: 100)
    #expect(
      FeedbackCursorClock.elapsed(from: start, to: start.addingTimeInterval(-30)) == "0:00")
  }
}
