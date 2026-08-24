import CoreGraphics
import Foundation

/// Where the recording cursor may sit, and how big it is.
///
/// Pure geometry, deliberately outside the view: the cursor is `#if os(iOS)`
/// SwiftUI and cannot be measured in a macOS test, but "can it end up somewhere
/// unreachable" is exactly the question that needs a test. The bar this replaces
/// was pinned under the status bar with no inset, which put its controls behind
/// the clock and battery (#1184).
enum FeedbackCursorGeometry {
  /// Nib inset from the leading edge. Small: the nib IS the pointer, so it must
  /// be able to reach close to what it points at.
  static let leadingInset: CGFloat = 8
  /// Room kept on the trailing side for the label that hangs off the nib.
  static let labelReserve: CGFloat = 120
  /// Clearance below the nib for the label's own height.
  static let bottomReserve: CGFloat = 44
  /// Clearance under the top safe-area edge.
  static let topInset: CGFloat = 4

  /// Keeps the nib inside the safe area. Never behind the clock, never under the
  /// home indicator, and never so far right that the label runs off screen.
  static func clamp(
    _ point: CGPoint, in size: CGSize, safeTop: CGFloat, safeBottom: CGFloat
  ) -> CGPoint {
    let minX = leadingInset
    let maxX = max(minX, size.width - labelReserve)
    let minY = safeTop + topInset
    let maxY = max(minY, size.height - safeBottom - bottomReserve)
    return CGPoint(
      x: min(max(point.x, minX), maxX),
      y: min(max(point.y, minY), maxY))
  }

  /// Where the cursor first appears: horizontally centred, above the midline so
  /// it does not cover the content people usually shake about.
  static func home(in size: CGSize) -> CGPoint {
    CGPoint(x: size.width / 2, y: size.height * 0.42)
  }

  /// Hit box for "did this touch land on the cursor". Padded to a 44pt minimum
  /// so a touch-down that is really the start of a drag is never mistaken for a
  /// background tap that dismisses the ink.
  static func hitBox(nib: CGPoint, measured: CGSize) -> CGRect {
    CGRect(
      x: nib.x - 6, y: nib.y - 6,
      width: max(measured.width, 44) + 12,
      height: max(measured.height, 34) + 12)
  }
}

/// The cursor's elapsed-time readout.
///
/// Deliberately outside the UIKit gate: it is pure formatting, and the view that
/// draws it cannot be reached from a macOS test target.
enum FeedbackCursorClock {
  static func elapsed(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    return String(format: "%01d:%02d", seconds / 60, seconds % 60)
  }
}
