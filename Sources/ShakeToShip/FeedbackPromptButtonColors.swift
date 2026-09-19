import SwiftUI

/// The colors of the shake prompt's primary action - both halves of the pair,
/// owned by the SDK.
///
/// #1389: the prompt used `.buttonStyle(.borderedProminent)`, which fills with
/// the HOST app's tint and draws its label white. A host that tints near-white
/// in dark mode renders a white label on a white fill. A Life Story tints its
/// root with `AliColors.ink`, which is `#F3EAD9` in dark mode: white on that is
/// 1.19:1, and the reporter could not read the button at all.
///
/// The SDK cannot see, and must not depend on, the host's tint - so it stops
/// inheriting one. Legibility of a bug-report control outranks brand match:
/// the fill is always the opposite end of the scale from the sheet behind it.
///
/// The pair is plain sRGB rather than a semantic `UIColor`, so the contrast
/// floor is checkable in a unit test on any platform instead of only inside a
/// rendered trait collection.
enum FeedbackPromptButtonColors {
  /// One sRGB color, components in 0...1.
  struct RGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ hex: UInt32) {
      red = Double((hex >> 16) & 0xFF) / 255
      green = Double((hex >> 8) & 0xFF) / 255
      blue = Double(hex & 0xFF) / 255
    }
  }

  /// WCAG 2.1 AA for a >= 17pt semibold button label is 3:1 (large text). The
  /// prompt holds itself to the 4.5:1 body floor: it is the one control a user
  /// reaches for when something is already wrong.
  static let contrastFloor = 4.5

  static func fill(dark: Bool) -> RGB { dark ? RGB(0xF2F2F7) : RGB(0x1C1C1E) }
  static func label(dark: Bool) -> RGB { dark ? RGB(0x1C1C1E) : RGB(0xFFFFFF) }

  /// WCAG 2.1 relative luminance.
  static func luminance(_ c: RGB) -> Double {
    func channel(_ v: Double) -> Double {
      v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
  }

  /// WCAG 2.1 contrast ratio, 1...21.
  static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
    let (hi, lo) = {
      let (x, y) = (luminance(a), luminance(b))
      return x >= y ? (x, y) : (y, x)
    }()
    return (hi + 0.05) / (lo + 0.05)
  }

  static var fillColor: Color { adaptive(light: fill(dark: false), dark: fill(dark: true)) }
  static var labelColor: Color { adaptive(light: label(dark: false), dark: label(dark: true)) }

  private static func swiftUIColor(_ c: RGB) -> Color {
    Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
  }

  private static func adaptive(light: RGB, dark: RGB) -> Color {
    #if canImport(UIKit)
    return Color(UIColor { trait in
      let chosen = trait.userInterfaceStyle == .dark ? dark : light
      return UIColor(red: chosen.red, green: chosen.green, blue: chosen.blue, alpha: 1)
    })
    #else
    return swiftUIColor(light)
    #endif
  }
}
