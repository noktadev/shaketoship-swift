import SwiftUI

/// Nil values preserve the host environment and native control appearance.
public struct ShakeToShipTheme {
  public enum ListStyle { case insetGrouped, plain }
  /// Explicit host language, also carried into the separate recording review window.
  public var locale: Locale?
  public var accent: Color?
  public var background: Color?
  public var surface: Color?
  public var primaryText: Color?
  public var secondaryText: Color?
  public var fontDesign: Font.Design?
  public var cornerRadius: CGFloat?
  public var listStyle: ListStyle?
  public var statusColors: [String: Color]

  public init(
    accent: Color? = nil, background: Color? = nil, surface: Color? = nil,
    primaryText: Color? = nil, secondaryText: Color? = nil,
    fontDesign: Font.Design? = nil, cornerRadius: CGFloat? = nil,
    listStyle: ListStyle? = nil, statusColors: [String: Color] = [:], locale: Locale? = nil
  ) {
    self.locale = locale
    self.accent = accent
    self.background = background
    self.surface = surface
    self.primaryText = primaryText
    self.secondaryText = secondaryText
    self.fontDesign = fontDesign
    self.cornerRadius = cornerRadius
    self.listStyle = listStyle
    self.statusColors = statusColors
  }
}

private struct ShakeToShipThemeKey: EnvironmentKey {
  static var defaultValue: ShakeToShipTheme { ShakeToShipTheme() }
}
extension EnvironmentValues {
  public var shakeToShipTheme: ShakeToShipTheme {
    get { self[ShakeToShipThemeKey.self] }
    set { self[ShakeToShipThemeKey.self] = newValue }
  }
}
extension View {
  public func shakeToShipTheme(_ theme: ShakeToShipTheme) -> some View {
    environment(\.shakeToShipTheme, theme)
  }
  func feedbackTheme() -> some View { modifier(FeedbackThemeModifier()) }
  func feedbackPrimaryText() -> some View { modifier(FeedbackPrimaryTextModifier()) }
  func feedbackBackground() -> some View { modifier(FeedbackBackgroundModifier()) }

  func feedbackListStyle() -> some View { modifier(FeedbackListStyleModifier()) }
  func feedbackRow() -> some View { modifier(FeedbackRowModifier()) }
  func feedbackCard() -> some View { modifier(FeedbackCardModifier()) }
  func feedbackSurface() -> some View { modifier(FeedbackCardModifier()) }
  func feedbackFont(_ fallback: Font, inherit: Bool = true) -> some View {
    modifier(FeedbackFontModifier(fallback: fallback, inherit: inherit))
  }
}
private struct FeedbackBackgroundModifier: ViewModifier {
  @Environment(\.shakeToShipTheme) private var theme
  func body(content: Content) -> some View {
    content.background(theme.background ?? theme.surface ?? .clear)
  }
}
private struct FeedbackPrimaryTextModifier: ViewModifier {
  @Environment(\.shakeToShipTheme) private var theme
  @ViewBuilder func body(content: Content) -> some View {
    if let color = theme.primaryText { content.foregroundStyle(color) } else { content }
  }
}
private struct FeedbackThemeModifier: ViewModifier {
  @Environment(\.shakeToShipTheme) private var theme
  @ViewBuilder func body(content: Content) -> some View {
    if let accent = theme.accent {
      styled(content).tint(accent)
    } else {
      styled(content)
    }
  }
  @ViewBuilder private func styled(_ content: Content) -> some View {
    if let design = theme.fontDesign {
      content.fontDesign(design)
    } else {
      content
    }
  }
}
private struct FeedbackRowModifier: ViewModifier {
  @Environment(\.shakeToShipTheme) private var theme
  @ViewBuilder func body(content: Content) -> some View {
    if let surface = theme.surface {
      if let radius = theme.cornerRadius {
        content.listRowBackground(
          RoundedRectangle(cornerRadius: radius).fill(surface).padding(.vertical, 4)
        )
        .listRowSeparator(.hidden)
      } else {
        content.listRowBackground(surface)
      }
    } else {
      content
    }
  }
}

private struct FeedbackFontModifier: ViewModifier {
  @Environment(\.font) private var font
  let fallback: Font
  var inherit = true
  func body(content: Content) -> some View { content.font(inherit ? font ?? fallback : fallback) }
}
private struct FeedbackListStyleModifier: ViewModifier {
  @Environment(\.shakeToShipTheme) private var theme
  @ViewBuilder func body(content: Content) -> some View {
    Group {
      switch theme.listStyle {
      #if canImport(UIKit)
        case .insetGrouped: content.listStyle(.insetGrouped)
      #else
        case .insetGrouped: content.listStyle(.automatic)
      #endif
      case .plain: content.listStyle(.plain)
      case nil: content
      }
    }
    .scrollContentBackground(theme.background == nil ? .automatic : .hidden)
    .background(theme.background ?? .clear)
  }
}
private struct FeedbackCardModifier: ViewModifier {
  @Environment(\.shakeToShipTheme) private var theme
  @ViewBuilder func body(content: Content) -> some View {
    if let radius = theme.cornerRadius {
      content.padding(16).background(
        theme.surface ?? .clear, in: RoundedRectangle(cornerRadius: radius))
    } else {
      content.padding(16).background(theme.surface ?? .clear)
    }
  }
}

/// Chip spacing stays inside the label; List and Form continue to own row insets.
struct FeedbackStatusChip: View {
  let idea: FeedbackIdea
  @Environment(\.shakeToShipTheme) private var theme
  var body: some View {
    let color = theme.statusColors[idea.status] ?? theme.secondaryText ?? .secondary
    Text(idea.statusLabel).feedbackFont(.caption.weight(.medium), inherit: false).lineLimit(1)
      .foregroundStyle(color)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
  }
}
