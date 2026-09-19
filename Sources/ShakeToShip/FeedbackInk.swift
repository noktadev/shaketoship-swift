import CoreGraphics
import Foundation
import Observation

/// Pure fade maths for the annotation trail, kept out of the SwiftUI view so it
/// can be tested on macOS - the trail itself is `#if os(iOS)` and no test host
/// can render it.
enum FeedbackInkFade {
  /// Total time from stroke to fully gone.
  static let lifetime: TimeInterval = 6
  /// Ink holds at full strength this long, then fades over the remainder.
  ///
  /// Measured in the island lab: a linear fade from t=0 reads as "gone in about
  /// three seconds" even at a nominal 5.5s lifetime - the stroke was already
  /// invisible at the halfway mark. Holding first is what makes six seconds
  /// FEEL like six seconds.
  static let hold: TimeInterval = 4
  /// How long a background-tap dismissal takes to clear the ink. Long enough
  /// not to read as a glitch, short enough not to fight the tap that caused it.
  static let dismissDuration: TimeInterval = 0.22

  /// 1 while held, then eased to 0 by `lifetime`. Clamped at both ends.
  static func life(age: TimeInterval) -> Double {
    if age <= hold { return age < 0 ? 0 : 1 }
    if age >= lifetime { return 0 }
    let t = (age - hold) / (lifetime - hold)
    return max(0, 1 - t * t)
  }

  /// Multiplier applied while a dismissal is animating out. `nil` means no
  /// dismissal is in flight.
  static func dismissFactor(now: TimeInterval, dismissedAt: TimeInterval?) -> Double {
    guard let dismissedAt else { return 1 }
    return max(0, 1 - (now - dismissedAt) / dismissDuration)
  }
}

/// One sampled point of a stroke. `t` is absolute so fade is a pure function of
/// wall time - there is no per-point animation state to keep in sync.
struct FeedbackInkPoint: Equatable, Sendable {
  let x: Double
  let y: Double
  let t: TimeInterval
}

/// Drops strokes that have fully faded, so a long recording cannot grow the
/// buffer without bound. The ink is transient by definition, so nothing is lost.
enum FeedbackInkBuffer {
  static func pruned(
    _ strokes: [[FeedbackInkPoint]], now: TimeInterval
  ) -> [[FeedbackInkPoint]] {
    let cutoff = now - FeedbackInkFade.lifetime
    return strokes.filter { stroke in stroke.contains { $0.t > cutoff } }
  }
}

/// The annotation state the two halves of the cursor share.
///
/// The pill draws (it owns the drag) and the canvas renders, and after #1391
/// they live in different places: the pill needs touches above the host's modal
/// presentations, which takes a window of its own, while the ink is only ever
/// delivered to a reviewer by the captured video, which means it has to stay
/// inside the window ReplayKit captures. One shared object is what lets the two
/// disagree about where they are drawn and still agree about what is drawn.
///
/// Also owns "was that touch the pill or the app", which used to sit inline in
/// the view where no test could reach it.
@MainActor
@Observable
final class FeedbackInkCanvas {
  private(set) var strokes: [[FeedbackInkPoint]] = []
  /// When a background tap started retiring the ink; nil while it is live.
  private(set) var dismissedAt: TimeInterval?
  /// The pill's hit box in host-window coordinates, published by the pill.
  /// nil until the pill has laid out once.
  var cursorBox: CGRect?
  /// #1092's "shake again to stop" hint. It is non-interactive, so it rides the
  /// captured layer rather than needing a window.
  var stopHintVisible = false
  /// Counts retirements. The pill collapses its expanded row on the same touch
  /// that retires the ink, and the touch is observed by the layer, not the pill -
  /// so this is how the pill hears about it.
  private(set) var retirements = 0

  /// Opens a stroke. A drag is also an explicit "I still want this ink", so a
  /// dismissal in flight is cancelled.
  func beginStroke() {
    dismissedAt = nil
    strokes.append([])
  }

  func append(x: Double, y: Double, at t: TimeInterval) {
    let point = FeedbackInkPoint(x: x, y: y, t: t)
    if strokes.isEmpty {
      strokes = [[point]]
    } else {
      strokes[strokes.count - 1].append(point)
    }
  }

  /// Closes the stroke and drops whatever has fully faded.
  func endStroke(now: TimeInterval) {
    strokes = FeedbackInkBuffer.pruned(strokes, now: now)
  }

  /// A touch-down somewhere on the app retires the ink. Returns false - and
  /// changes nothing - when the touch landed on the pill (that is the start of a
  /// drag), when there is no ink, or when a dismissal is already running.
  @discardableResult
  func retire(touchAt point: CGPoint, now: TimeInterval) -> Bool {
    guard !strokes.isEmpty, dismissedAt == nil else { return false }
    if let cursorBox, cursorBox.contains(point) { return false }
    dismissedAt = now
    retirements += 1
    return true
  }

  func clear() {
    strokes = []
    dismissedAt = nil
    stopHintVisible = false
  }
}

/// Whether a scene-teardown notification belongs to the scene that owns a
/// presenter's window. `UIScene.didDisconnectNotification` is posted for every
/// scene, so an unscoped observer would tear the pill's window down when an
/// unrelated window closes, mid-recording, with nothing to put it back.
///
/// Identity only, and outside the UIKit gate so the rule itself is testable.
/// Takes `ObjectIdentifier` rather than the objects: a `Notification` is
/// task-isolated under Swift 6 strict concurrency, so the caller has to reduce it
/// to a Sendable value before hopping to the MainActor.
enum FeedbackSceneTeardown {
  static func dismisses(notified: ObjectIdentifier?, owner: ObjectIdentifier?) -> Bool {
    guard let notified, let owner else { return false }
    return notified == owner
  }
}
