import CoreGraphics
import Foundation
import Testing

@testable import ShakeToShip

/// The annotation ink is delivered to a reviewer by ONE route: the captured
/// video. `FeedbackInkPoint` is not `Codable`, nothing writes strokes to the
/// session dir, and the uploader sends only `events.json`, `recording.mov` and
/// the composer's attachments. So the ink has to be drawn inside the window
/// ReplayKit captures, while the pill has to be touchable above the host's
/// modal presentations (#1391) - two different places.
///
/// `FeedbackInkCanvas` is the state both halves share. It also owns the
/// "is this touch on the pill or on the app" rule, which used to be inline in
/// the view and therefore untestable.
@Suite struct FeedbackInkCanvasTests {
  private let box = CGRect(x: 100, y: 100, width: 80, height: 40)

  @Test @MainActor func aStrokeCollectsThePointsItIsGiven() {
    let canvas = FeedbackInkCanvas()
    canvas.beginStroke()
    canvas.append(x: 1, y: 2, at: 10)
    canvas.append(x: 3, y: 4, at: 11)
    #expect(canvas.strokes.count == 1)
    #expect(canvas.strokes.first?.count == 2)
    #expect(canvas.strokes.first?.last == FeedbackInkPoint(x: 3, y: 4, t: 11))
  }

  @Test @MainActor func separateDragsAreSeparateStrokes() {
    let canvas = FeedbackInkCanvas()
    canvas.beginStroke()
    canvas.append(x: 1, y: 1, at: 10)
    canvas.append(x: 2, y: 2, at: 11)
    canvas.endStroke(now: 11)
    canvas.beginStroke()
    canvas.append(x: 9, y: 9, at: 12)
    canvas.append(x: 8, y: 8, at: 13)
    #expect(canvas.strokes.count == 2)
  }

  /// The buffer cannot grow without bound over a long recording.
  @Test @MainActor func endingAStrokeDropsWhatHasFullyFaded() {
    let canvas = FeedbackInkCanvas()
    canvas.beginStroke()
    canvas.append(x: 1, y: 1, at: 0)
    canvas.append(x: 2, y: 2, at: 0)
    canvas.endStroke(now: FeedbackInkFade.lifetime + 1)
    #expect(canvas.strokes.isEmpty)
  }

  /// A tap on the app retires the ink: annotation is transient.
  @Test @MainActor func aTapOnTheAppRetiresTheInk() {
    let canvas = FeedbackInkCanvas()
    canvas.cursorBox = box
    canvas.beginStroke()
    canvas.append(x: 1, y: 1, at: 10)
    #expect(canvas.retire(touchAt: CGPoint(x: 10, y: 10), now: 12))
    #expect(canvas.dismissedAt == 12)
  }

  /// Grabbing the pill is the start of a drag, not a background tap. Reading
  /// this wrong wipes the ink every time the user reaches for the control.
  @Test @MainActor func aTouchOnThePillDoesNotRetireTheInk() {
    let canvas = FeedbackInkCanvas()
    canvas.cursorBox = box
    canvas.beginStroke()
    canvas.append(x: 1, y: 1, at: 10)
    #expect(!canvas.retire(touchAt: CGPoint(x: box.midX, y: box.midY), now: 12))
    #expect(canvas.dismissedAt == nil)
  }

  /// The pill collapses its expanded row on the touch that retires the ink, and
  /// only on that touch. The pill cannot see the touch (the layer observes it),
  /// so it watches this count. A tap on the pill, or a tap with no ink, must not
  /// bump it, or reaching for the stop button would close the row first.
  @Test @MainActor func onlyARealRetirementAsksThePillToCollapse() {
    let canvas = FeedbackInkCanvas()
    canvas.cursorBox = box
    #expect(canvas.retirements == 0)
    _ = canvas.retire(touchAt: CGPoint(x: 10, y: 10), now: 1)
    #expect(canvas.retirements == 0)  // no ink yet
    canvas.beginStroke()
    canvas.append(x: 1, y: 1, at: 2)
    _ = canvas.retire(touchAt: CGPoint(x: box.midX, y: box.midY), now: 3)
    #expect(canvas.retirements == 0)  // that was a grab of the pill
    _ = canvas.retire(touchAt: CGPoint(x: 10, y: 10), now: 4)
    #expect(canvas.retirements == 1)
  }

  @Test @MainActor func thereIsNothingToRetireWithoutInk() {
    let canvas = FeedbackInkCanvas()
    #expect(!canvas.retire(touchAt: CGPoint(x: 10, y: 10), now: 12))
    #expect(canvas.dismissedAt == nil)
  }

  /// A second tap during the fade must not restart it.
  @Test @MainActor func aSecondTapDuringTheFadeChangesNothing() {
    let canvas = FeedbackInkCanvas()
    canvas.beginStroke()
    canvas.append(x: 1, y: 1, at: 10)
    #expect(canvas.retire(touchAt: CGPoint(x: 10, y: 10), now: 12))
    #expect(!canvas.retire(touchAt: CGPoint(x: 11, y: 11), now: 12.1))
    #expect(canvas.dismissedAt == 12)
  }

  /// Drawing again revives ink that a tap just retired.
  @Test @MainActor func anewStrokeCancelsAPendingDismissal() {
    let canvas = FeedbackInkCanvas()
    canvas.beginStroke()
    canvas.append(x: 1, y: 1, at: 10)
    _ = canvas.retire(touchAt: CGPoint(x: 10, y: 10), now: 12)
    canvas.beginStroke()
    #expect(canvas.dismissedAt == nil)
  }
}

/// #1391 follow-up: the pill's window is torn down on scene disconnect, and the
/// notification is posted for EVERY scene. Dismissing on another scene's
/// disconnect would remove the stop control from a recording that is still
/// running, with nothing to put it back.
@Suite struct FeedbackSceneTeardownTests {
  @Test func theOwningScenesDisconnectTearsTheWindowDown() {
    let owner = NSObject()
    let id = ObjectIdentifier(owner)
    #expect(FeedbackSceneTeardown.dismisses(notified: id, owner: id))
    withExtendedLifetime(owner) {}
  }

  @Test func anotherScenesDisconnectIsIgnored() {
    let owner = NSObject()
    let other = NSObject()
    #expect(
      !FeedbackSceneTeardown.dismisses(
        notified: ObjectIdentifier(other), owner: ObjectIdentifier(owner)))
    withExtendedLifetime((owner, other)) {}
  }

  @Test func anUnattributedNotificationIsIgnored() {
    let owner = NSObject()
    #expect(!FeedbackSceneTeardown.dismisses(notified: nil, owner: ObjectIdentifier(owner)))
    #expect(!FeedbackSceneTeardown.dismisses(notified: ObjectIdentifier(owner), owner: nil))
    withExtendedLifetime(owner) {}
  }
}
