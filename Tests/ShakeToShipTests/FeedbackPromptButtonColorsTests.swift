import XCTest

@testable import ShakeToShip

/// #1389 guard. The reporter could not read the prompt's primary button in dark
/// mode: it inherited the host's tint (near-white) and drew a white label on it.
/// These assertions pin the pair in BOTH appearances, so no future host tint and
/// no "just make it prominent" edit can put the label and the fill on the same
/// end of the scale again.
final class FeedbackPromptButtonColorsTests: XCTestCase {
  func testPrimaryButtonMeetsTheContrastFloorInLightMode() {
    let ratio = FeedbackPromptButtonColors.contrastRatio(
      FeedbackPromptButtonColors.label(dark: false),
      FeedbackPromptButtonColors.fill(dark: false))
    XCTAssertGreaterThanOrEqual(
      ratio, FeedbackPromptButtonColors.contrastFloor,
      "light-mode prompt button label/fill contrast is \(ratio):1")
  }

  func testPrimaryButtonMeetsTheContrastFloorInDarkMode() {
    let ratio = FeedbackPromptButtonColors.contrastRatio(
      FeedbackPromptButtonColors.label(dark: true),
      FeedbackPromptButtonColors.fill(dark: true))
    XCTAssertGreaterThanOrEqual(
      ratio, FeedbackPromptButtonColors.contrastFloor,
      "dark-mode prompt button label/fill contrast is \(ratio):1")
  }

  /// The defect itself, stated as a value: white on A Life Story's dark-mode
  /// tint (`AliColors.ink`, #F3EAD9) is 1.19:1. If the ratio function ever
  /// reports that pair as acceptable, the two tests above prove nothing.
  func testContrastRatioRejectsTheReportedWhiteOnWhitePair() {
    let ratio = FeedbackPromptButtonColors.contrastRatio(
      FeedbackPromptButtonColors.RGB(0xFFFFFF),
      FeedbackPromptButtonColors.RGB(0xF3EAD9))
    XCTAssertLessThan(ratio, 1.3, "white on #F3EAD9 should be ~1.19:1, got \(ratio):1")
    XCTAssertLessThan(ratio, FeedbackPromptButtonColors.contrastFloor)
  }

  func testContrastRatioIsSymmetricAndBounded() {
    let black = FeedbackPromptButtonColors.RGB(0x000000)
    let white = FeedbackPromptButtonColors.RGB(0xFFFFFF)
    XCTAssertEqual(
      FeedbackPromptButtonColors.contrastRatio(black, white),
      FeedbackPromptButtonColors.contrastRatio(white, black),
      accuracy: 0.0001)
    XCTAssertEqual(FeedbackPromptButtonColors.contrastRatio(black, white), 21, accuracy: 0.01)
    XCTAssertEqual(FeedbackPromptButtonColors.contrastRatio(white, white), 1, accuracy: 0.0001)
  }

  /// The fill must invert with the appearance; a fill that is light in both
  /// schemes is how the defect shipped.
  func testFillInvertsBetweenAppearances() {
    let light = FeedbackPromptButtonColors.luminance(FeedbackPromptButtonColors.fill(dark: false))
    let dark = FeedbackPromptButtonColors.luminance(FeedbackPromptButtonColors.fill(dark: true))
    XCTAssertLessThan(light, dark, "light-mode fill should be the darker of the two")
  }
}
