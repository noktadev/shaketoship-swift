import Foundation

/// Pure formatting for tap events: everything the UIKit capture layer decides
/// that is worth testing lives here, so the hierarchy walk itself stays thin.
public enum FeedbackTapFormatting {
  /// Longest element string recorded, including the ellipsis.
  public static let elementMaxLength = 80

  /// A coordinate as a 0-1 fraction of `extent`, clamped to bounds and rounded
  /// to 2 decimals (finer precision is noise for an agent reading the trail).
  public static func normalized(_ value: Double, in extent: Double) -> Double {
    guard extent > 0 else { return 0 }
    let fraction = min(max(value / extent, 0), 1)
    return (fraction * 100).rounded() / 100
  }

  /// The best available description of a tapped element: accessibility label,
  /// else accessibility identifier, else a title (e.g. a button's title text).
  /// Blank candidates are skipped, whitespace runs collapse to single spaces,
  /// and the result is capped at `elementMaxLength`. nil when nothing usable.
  public static func elementText(label: String?, identifier: String?, title: String?) -> String? {
    for candidate in [label, identifier, title] {
      guard let cleaned = clean(candidate) else { continue }
      return truncate(cleaned)
    }
    return nil
  }

  private static func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.isEmpty ? nil : collapsed
  }

  private static func truncate(_ value: String) -> String {
    guard value.count > elementMaxLength else { return value }
    return value.prefix(elementMaxLength - 1) + "\u{2026}"
  }
}

extension FeedbackTapFormatting {
  /// One node discovered while walking a hierarchy for a tap point: how many
  /// hops from the root it sits at, and its already-resolved name (nil when
  /// the node exposed nothing nameable via `elementText`).
  public struct AccessibilityHit {
    public let depth: Int
    public let name: String?

    public init(depth: Int, name: String?) {
      self.depth = depth
      self.name = name
    }
  }

  /// Picks the tap's element name out of every node whose on-screen frame
  /// contained the point: the DEEPEST node with a usable name wins (the
  /// innermost labeled control beats its container), falling back toward
  /// the root when the deepest matches exposed nothing nameable. Ties at
  /// the same depth keep discovery order. nil when nothing in the walk had
  /// a usable name.
  ///
  /// Kept separate from the tree walk itself so the "prefer deepest, else
  /// fall back up" rule is exercised by tests without a live UIKit hierarchy.
  public static func deepestNamedHit(_ hits: [AccessibilityHit]) -> String? {
    hits
      .sorted { $0.depth > $1.depth }
      .lazy
      .compactMap(\.name)
      .first
  }
}
