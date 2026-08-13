import CoreGraphics

/// Sizing for the in-app recording indicator drawn by `FeedbackRecordingBar`.
///
/// Deliberately outside the view's `#if canImport(UIKit)` guard: the view only
/// compiles on UIKit platforms, so metrics kept inside it would compile out of
/// the macOS test build and the legibility floor from #357 would go unasserted.
enum FeedbackRecordingBarMetrics {
  /// Filled red core. Larger than the original flat 9pt dot.
  static let coreDiameter: CGFloat = 14
  /// Outer pulsing halo - the size the indicator actually reads at.
  static let haloDiameter: CGFloat = 22
  /// Floor the recording indicator must read at on device (#357).
  static let minimumLegibleDiameter: CGFloat = 20
}
