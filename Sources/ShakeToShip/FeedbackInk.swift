import Foundation

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
