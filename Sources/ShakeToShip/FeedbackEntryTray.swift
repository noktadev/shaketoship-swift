#if canImport(UIKit)
import SwiftUI

/// The Jam record control: "Tap to record" above one big filled accent circle with a white
/// waveform. One tap starts recording.
struct FeedbackRecordHero: View {
  let action: () -> Void
  @Environment(\.shakeToShipTheme) private var theme
  private var accent: Color { theme.accent ?? .accentColor }
  var body: some View {
    VStack(spacing: 16) {
      Text("Tap to record").feedbackFont(.headline, inherit: false)
        .foregroundStyle(theme.primaryText ?? .primary).lineLimit(2)
        .multilineTextAlignment(.center).accessibilityHidden(true)
      Button(action: action) {
        Image(systemName: "waveform")
          .font(.system(size: 46, weight: .semibold)).foregroundStyle(.white)
          .frame(width: 152, height: 152)
          .background(accent.gradient, in: Circle())
          .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
          .padding(8).background(accent.opacity(0.12), in: Circle())
          .shadow(color: accent.opacity(0.32), radius: 16, x: 0, y: 8)
      }.buttonStyle(FeedbackRecordHeroStyle())
        .accessibilityLabel("Tap to record").accessibilityIdentifier("ShakeToShip.bug.record")
    }
  }
}

private struct FeedbackRecordHeroStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
      .opacity(configuration.isPressed ? 0.9 : 1)
      .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
  }
}

/// One compact row under the record control.
struct FeedbackTrayRow: Identifiable {
  enum Kind {
    case action(() -> Void)
    case route(ShakeToShipRoute)
  }
  let title: String
  let symbol: String
  let kind: Kind
  var id: String { title }

  static func action(_ action: FeedbackHubEntryAction, title: String? = nil,
    perform: @escaping () -> Void) -> Self {
    .init(title: title ?? action.title, symbol: action.symbol, kind: .action(perform))
  }
  static func route(_ action: FeedbackHubEntryAction, _ route: ShakeToShipRoute) -> Self {
    .init(title: action.title, symbol: action.symbol, kind: .route(route))
  }
}

extension FeedbackHubEntryAction {
  var symbol: String {
    switch self {
    case .record: "record.circle"
    case .write: "square.and.pencil"
    case .report: "ladybug"
    case .suggest: "lightbulb"
    case .ideas: "arrow.up.square"
    case .inbox: "tray"
    }
  }
}

/// The first feedback tray. Every entry point opens this: the record control leads,
/// and the other options follow as compact rows. Without a recorder (simulator,
/// Catalyst, or no registered handler) the control is absent, so no button is dead.
struct FeedbackEntryTray: View {
  let recordAvailable: Bool
  let onRecord: () -> Void
  let rows: [FeedbackTrayRow]
  /// Reports the natural height so the sheet can open at exactly this size.
  var onHeight: (CGFloat) -> Void = { _ in }
  @Environment(\.shakeToShipTheme) private var theme
  var body: some View {
    VStack(spacing: 24) {
      if recordAvailable {
        FeedbackRecordHero(action: onRecord)
      } else {
        Text("Any feedback to share?").feedbackFont(.title3.bold(), inherit: false).feedbackPrimaryText()
          .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
        FeedbackRecordingDeviceHint()
      }
      if !rows.isEmpty {
        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            if index > 0 { Divider().padding(.leading, 56) }
            cell(row)
          }
        }
        .background(theme.surface ?? Color(uiColor: .secondarySystemGroupedBackground),
          in: RoundedRectangle(cornerRadius: min(theme.cornerRadius ?? 12, 16)))
      }
    }
    .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 16)
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
  }

  @ViewBuilder private func cell(_ row: FeedbackTrayRow) -> some View {
    switch row.kind {
    case .action(let perform):
      Button(action: perform) { label(row) }.buttonStyle(.plain)
    case .route(let route):
      NavigationLink(value: route) { label(row) }.buttonStyle(.plain)
    }
  }

  private func label(_ row: FeedbackTrayRow) -> some View {
    HStack(spacing: 12) {
      Image(systemName: row.symbol).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
      Text(row.title).foregroundStyle(theme.primaryText ?? .primary).lineLimit(2)
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary).accessibilityHidden(true)
    }
    .feedbackFont(.body, inherit: false)
    .padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
  }
}

/// Sizes the tray sheet to its content so it opens without scrolling, and lets a pushed
/// route use the full height. Larger text caps at `.large` and the content scrolls.
struct FeedbackTrayPresentation: ViewModifier {
  let contentHeight: CGFloat
  let pushed: Bool
  @State private var detent: PresentationDetent = .large
  private var tray: PresentationDetent { .height(max(280, ceil(contentHeight) + 16)) }
  func body(content: Content) -> some View {
    content
      .feedbackCardPresentation(detents: [tray, .large])
      .presentationDetents([tray, .large], selection: $detent)
      .onAppear { detent = pushed ? .large : tray }
      .onChange(of: contentHeight) { _, _ in if !pushed { detent = tray } }
      .onChange(of: pushed) { _, pushed in detent = pushed ? .large : tray }
  }
}

extension View {
  func feedbackTrayPresentation(contentHeight: CGFloat, pushed: Bool = false) -> some View {
    modifier(FeedbackTrayPresentation(contentHeight: contentHeight, pushed: pushed))
  }
}
#endif
