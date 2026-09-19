import CoreGraphics
import Foundation
import Testing

@testable import ShakeToShip

/// #1391: the cursor was an `.overlay` on the host's root view, so A Life
/// Story's call screen - a `fullScreenCover` - rendered on top of it and the
/// pill with the stop control became unreachable mid-recording.
///
/// It lives in a dedicated window above every presentation now. The rule that
/// keeps that window from eating the app's touches is pure geometry and is
/// pinned here; the window itself is UIKit and cannot be built in a macOS test.
@Suite struct FeedbackPassThroughHitTests {
  private let nib = CGPoint(x: 120, y: 300)
  private var box: CGRect { FeedbackCursorGeometry.hitBox(nib: nib, measured: CGSize(width: 90, height: 28)) }

  @Test func aTouchOnTheCursorIsClaimed() {
    #expect(FeedbackPassThroughHit.claims(point: nib, interactive: box))
    #expect(
      FeedbackPassThroughHit.claims(
        point: CGPoint(x: box.midX, y: box.midY), interactive: box))
  }

  /// The whole rest of the screen must reach the app below, or the window would
  /// reintroduce #1183 (a recorder overlay that made the app unusable) at a
  /// level no host could work around.
  @Test func aTouchAnywhereElseIsDeclined() {
    #expect(!FeedbackPassThroughHit.claims(point: CGPoint(x: 10, y: 10), interactive: box))
    #expect(
      !FeedbackPassThroughHit.claims(point: CGPoint(x: nib.x, y: nib.y + 400), interactive: box))
    #expect(
      !FeedbackPassThroughHit.claims(point: CGPoint(x: nib.x + 500, y: nib.y), interactive: box))
  }

  /// Before the cursor has reported its frame there is nothing to claim. Failing
  /// open here would block every touch on the app for the first frames of a
  /// recording.
  @Test func nothingIsClaimedBeforeTheCursorHasReportedItsFrame() {
    #expect(!FeedbackPassThroughHit.claims(point: nib, interactive: nil))
    #expect(!FeedbackPassThroughHit.claims(point: nib, interactive: .zero))
  }

  /// The box carries the 44pt minimum target, so the claimed region is never
  /// smaller than the thing a finger has to hit.
  @Test func theClaimedRegionKeepsTheMinimumTouchTarget() {
    let tight = FeedbackCursorGeometry.hitBox(nib: nib, measured: .zero)
    #expect(FeedbackPassThroughHit.claims(point: CGPoint(x: nib.x + 40, y: nib.y), interactive: tight))
    #expect(
      !FeedbackPassThroughHit.claims(point: CGPoint(x: nib.x + 200, y: nib.y), interactive: tight))
  }
}

/// Source guards for the window contract. `FeedbackCursorWindow` is UIKit +
/// SwiftUI behind the device gate, so no macOS test can instantiate it; these
/// read the source, the same way `FeedbackRecordingCursorSourceTests` does for
/// the layout invariants that only ever broke on device.
@Suite struct FeedbackCursorWindowSourceTests {
  private static func source(_ name: String) -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    let file = url.appendingPathComponent("Sources/ShakeToShip/\(name)")
    return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
  }

  @Test func windowSourceIsReadable() {
    #expect(Self.source("FeedbackCursorWindow.swift").contains("class FeedbackPassThroughWindow"))
  }

  /// The fix itself: a window level above the normal level, which is where a
  /// host app's own covers and sheets live.
  @Test func theCursorWindowSitsAboveEveryHostPresentation() {
    #expect(Self.source("FeedbackCursorWindow.swift").contains("windowLevel = .alert"))
  }

  /// Touches outside the cursor must pass through. `hitTest` returning nil is
  /// the mechanism; losing it would block the whole screen.
  @Test func theWindowDeclinesTouchesOutsideTheCursor() {
    let source = Self.source("FeedbackCursorWindow.swift")
    #expect(source.contains("override func hitTest"))
    #expect(source.contains("FeedbackPassThroughHit.claims"))
    #expect(source.contains("return nil"))
  }

  /// Never key: shake detection and the tap trail ride the host's key window,
  /// so making this one key would break both (same rule as the review window).
  @Test func theWindowIsNeverMadeKey() {
    #expect(!Self.source("FeedbackCursorWindow.swift").contains("makeKeyAndVisible"))
  }

  /// A second window is reported to be invisible to ReplayKit's in-app capture.
  /// The ink is only ever delivered by the video, so it stays a subview of the
  /// HOST window, lifted over the host's presentations by `zPosition` rather
  /// than by a window of its own.
  @Test func theInkIsDrawnInsideTheCapturedHostWindow() {
    let source = Self.source("FeedbackCursorWindow.swift")
    #expect(source.contains("hostWindow"))
    #expect(source.contains("zPosition"))
    #expect(source.contains("FeedbackInkLayer"))
  }

  /// The ink layer covers the whole screen, so if it ever took a touch it would
  /// block the app completely.
  @Test func theInkLayerTakesNoTouches() {
    #expect(Self.source("FeedbackCursorWindow.swift").contains("isUserInteractionEnabled = false"))
  }

  /// The pill belongs in the scene the recording was started from, not in
  /// whichever scene happens to be first in `connectedScenes`.
  @Test func thePillFollowsTheHostWindowScene() {
    #expect(Self.source("FeedbackCursorWindow.swift").contains("hostWindow?.windowScene"))
  }

  /// `UIScene.didDisconnectNotification` is posted for every scene. Scoping the
  /// observer is what stops an unrelated scene closing from removing the stop
  /// control from a running recording.
  @Test func theTeardownObserverIsScopedToTheOwningScene() {
    let source = Self.source("FeedbackCursorWindow.swift")
    #expect(source.contains("object: scene"))
    #expect(source.contains("FeedbackSceneTeardown.dismisses"))
  }

  /// A hosting controller's view is opaque white by default, which over the
  /// whole screen would hide the app entirely.
  @Test func theWindowAndItsHostAreTransparent() {
    let source = Self.source("FeedbackCursorWindow.swift")
    #expect(source.contains("backgroundColor = .clear"))
    #expect(source.contains("isOpaque = false"))
  }

  /// #1391 regression fence: an `.overlay` on the host root is exactly what sat
  /// under the call screen. The cursor is only ever shown through the presenter.
  @Test func theModifierNoLongerOverlaysTheCursorOnTheHostRoot() {
    let source = Self.source("ShakeRecorderModifier.swift")
    #expect(!source.contains(".overlay(alignment: .topLeading)"))
    #expect(source.contains("cursorPresenter.show("))
    #expect(source.contains("cursorPresenter.dismiss()"))
  }

  /// The pill draws ink but never renders it: the trail belongs to the layer in
  /// the captured window. Putting it back in the pill would hide every
  /// annotation from the video again.
  @Test func thePillDoesNotRenderTheInkItself() {
    #expect(!Self.source("FeedbackRecordingCursor.swift").contains("FeedbackInkTrail("))
    #expect(Self.source("FeedbackInkTrail.swift").contains("struct FeedbackInkLayer"))
  }

  /// #1092's hint is non-interactive, so it rides the captured layer with the
  /// ink instead of staying a root overlay under the host's call screen.
  @Test func theStopHintRidesTheCapturedLayer() {
    let layer = Self.source("FeedbackInkTrail.swift")
    #expect(layer.contains("FeedbackShakeStopHint()"))
    #expect(!Self.source("ShakeRecorderModifier.swift").contains("FeedbackShakeStopHint()"))
  }
}
