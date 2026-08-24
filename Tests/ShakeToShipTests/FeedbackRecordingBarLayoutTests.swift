import Foundation
import Testing

/// #1183: mid-recording the whole screen was blurred and unusable. The bar's
/// two `maxHeight: .infinity` hit areas (added so the padding band above and
/// below the text was not a dead tap target) had nothing bounding the row, so
/// the HStack took the overlay's full height, `.ultraThinMaterial` blurred the
/// entire app, and the stop buttons became screen-sized targets. A user could
/// not operate the app they had just started recording.
///
/// The bar is `#if os(iOS)` SwiftUI - it cannot be instantiated or measured in
/// a macOS test - so this reads the source and pins the constraint that keeps
/// the row bounded. A layout regression here is invisible until someone builds
/// for a device, which is exactly why it shipped.
@Suite struct FeedbackRecordingBarLayoutTests {
  private static var source: String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    let file = url.appendingPathComponent("Sources/ShakeToShip/FeedbackRecordingBar.swift")
    return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
  }

  @Test func sourceIsReadable() {
    #expect(Self.source.contains("struct FeedbackRecordingBar"))
  }

  @Test func rowIsPinnedToItsOwnIdealHeight() {
    #expect(Self.source.contains(".fixedSize(horizontal: false, vertical: true)"))
  }

  /// The material is what actually paints over the app, so it must sit OUTSIDE
  /// the bound - i.e. after it in the modifier chain.
  @Test func materialBackgroundIsAppliedAfterTheHeightBound() throws {
    let source = Self.source
    let bound = try #require(source.range(of: ".fixedSize(horizontal: false, vertical: true)"))
    let material = try #require(source.range(of: ".background(.ultraThinMaterial)"))
    #expect(bound.lowerBound < material.lowerBound)
  }

  /// A fixed `height:` would clip the text at large Dynamic Type sizes - the
  /// same class of defect as the iPad truncation Apple cited. The row must be
  /// bounded by its own content, never by a hardcoded number.
  @Test func rowHeightIsNotHardcoded() {
    #expect(!Self.source.contains(".frame(height:"))
  }
}
