import Foundation
import Testing

@testable import ShakeToShip

@Suite struct FeedbackTapFormattingTests {
  @Test func normalizesToTwoDecimalFractionOfExtent() {
    #expect(FeedbackTapFormatting.normalized(195, in: 390) == 0.5)
    #expect(FeedbackTapFormatting.normalized(130, in: 390) == 0.33)
    #expect(FeedbackTapFormatting.normalized(0, in: 390) == 0)
    #expect(FeedbackTapFormatting.normalized(390, in: 390) == 1)
  }

  /// A touch can land outside the window bounds (edge gestures, rounding).
  @Test func clampsOutOfBoundsCoordinates() {
    #expect(FeedbackTapFormatting.normalized(-20, in: 390) == 0)
    #expect(FeedbackTapFormatting.normalized(500, in: 390) == 1)
  }

  /// A zero-extent window would divide by zero.
  @Test func zeroExtentNormalizesToZero() {
    #expect(FeedbackTapFormatting.normalized(10, in: 0) == 0)
  }

  @Test func prefersLabelOverIdentifierAndTitle() {
    #expect(
      FeedbackTapFormatting.elementText(label: "Practice", identifier: "home.cta", title: "PRACTICE")
        == "Practice")
  }

  @Test func fallsBackToIdentifierThenTitle() {
    #expect(
      FeedbackTapFormatting.elementText(label: nil, identifier: "home.cta", title: "PRACTICE")
        == "home.cta")
    #expect(
      FeedbackTapFormatting.elementText(label: nil, identifier: nil, title: "PRACTICE")
        == "PRACTICE")
  }

  /// Blank/whitespace-only values are treated as absent, not as a match.
  @Test func treatsBlankValuesAsAbsent() {
    #expect(
      FeedbackTapFormatting.elementText(label: "   ", identifier: "", title: "PRACTICE")
        == "PRACTICE")
    #expect(FeedbackTapFormatting.elementText(label: nil, identifier: nil, title: nil) == nil)
    #expect(FeedbackTapFormatting.elementText(label: "\n\t ", identifier: nil, title: nil) == nil)
  }

  @Test func trimsSurroundingWhitespaceAndCollapsesNewlines() {
    #expect(
      FeedbackTapFormatting.elementText(label: "  Start\nlesson  ", identifier: nil, title: nil)
        == "Start lesson")
  }

  @Test func truncatesAtEightyCharacters() {
    let long = String(repeating: "a", count: 200)
    let text = try! #require(
      FeedbackTapFormatting.elementText(label: long, identifier: nil, title: nil))
    #expect(text.count == FeedbackTapFormatting.elementMaxLength)
    #expect(text == String(repeating: "a", count: 79) + "\u{2026}")
  }

  @Test func keepsStringsAtTheLimitIntact() {
    let exact = String(repeating: "b", count: 80)
    #expect(FeedbackTapFormatting.elementText(label: exact, identifier: nil, title: nil) == exact)
  }

  // MARK: - deepestNamedHit

  /// The innermost labeled element beats its container, regardless of the
  /// order hits were discovered in.
  @Test func deepestNamedHitPrefersInnermostNonNilName() {
    let hits: [FeedbackTapFormatting.AccessibilityHit] = [
      .init(depth: 0, name: nil),
      .init(depth: 1, name: "Home"),
      .init(depth: 3, name: "Practice"),
      .init(depth: 2, name: nil),
    ]
    #expect(FeedbackTapFormatting.deepestNamedHit(hits) == "Practice")
  }

  /// When the deepest matches expose nothing nameable, fall back toward the
  /// root instead of returning nil outright.
  @Test func deepestNamedHitFallsBackUpWhenDeepestIsUnnamed() {
    let hits: [FeedbackTapFormatting.AccessibilityHit] = [
      .init(depth: 0, name: "Root"),
      .init(depth: 2, name: nil),
      .init(depth: 1, name: nil),
    ]
    #expect(FeedbackTapFormatting.deepestNamedHit(hits) == "Root")
  }

  @Test func deepestNamedHitReturnsNilWhenNothingNamed() {
    let hits: [FeedbackTapFormatting.AccessibilityHit] = [
      .init(depth: 0, name: nil),
      .init(depth: 1, name: nil),
    ]
    #expect(FeedbackTapFormatting.deepestNamedHit(hits) == nil)
  }

  @Test func deepestNamedHitHandlesEmptyList() {
    #expect(FeedbackTapFormatting.deepestNamedHit([]) == nil)
  }

  /// Stable sort: equal-depth hits keep their discovery order.
  @Test func deepestNamedHitKeepsDiscoveryOrderAtEqualDepth() {
    let hits: [FeedbackTapFormatting.AccessibilityHit] = [
      .init(depth: 2, name: "First"),
      .init(depth: 2, name: "Second"),
    ]
    #expect(FeedbackTapFormatting.deepestNamedHit(hits) == "First")
  }
}
