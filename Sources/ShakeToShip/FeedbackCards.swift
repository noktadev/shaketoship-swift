import SwiftUI

private struct FeedbackCardPresentedKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
  var feedbackCardPresented: Bool {
    get { self[FeedbackCardPresentedKey.self] }
    set { self[FeedbackCardPresentedKey.self] = newValue }
  }
}

/// Shared information order for the SDK's short interruption cards.
struct FeedbackCard<Content: View>: View {
  let symbol: String
  let title: String
  let message: String
  @ViewBuilder let content: () -> Content
  @Environment(\.shakeToShipTheme) private var theme
  @Environment(\.feedbackCardPresented) private var presented
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.title3)
        .foregroundStyle(.tint).frame(width: 44, height: 44)
        .background(.tint.opacity(0.15), in: Circle()).accessibilityHidden(true)
      Text(title).feedbackFont(.title3.bold(), inherit: false).feedbackPrimaryText()
        .lineLimit(1).minimumScaleFactor(0.65).accessibilityAddTraits(.isHeader)
      Text(message).feedbackFont(.subheadline, inherit: false)
        .foregroundStyle(theme.secondaryText ?? .secondary)
        .multilineTextAlignment(.center).lineLimit(3)
      content()
      Label("We run on Shake to Ship", systemImage: "waveform")
        .feedbackFont(.caption2, inherit: false).foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    .frame(maxWidth: .infinity).padding(20)
    .background(presented ? .clear : theme.surface ?? .clear, in: RoundedRectangle(cornerRadius: theme.cornerRadius ?? 24))
    .feedbackTheme()
  }
}

struct FeedbackCardAction: View {
  let title: String
  let action: () -> Void
  var body: some View {
    Button(action: action) { Text(title).frame(maxWidth: .infinity) }
      .buttonStyle(.borderedProminent).controlSize(.large)
  }
}

#if canImport(UIKit)
import UIKit

extension View {
  func feedbackCardPresentation(dismissDisabled: Bool = false, detents: Set<PresentationDetent> = [.medium]) -> some View {
    modifier(FeedbackCardPresentation(dismissDisabled: dismissDisabled, detents: detents))
  }
}
private struct FeedbackCardPresentation: ViewModifier {
  let dismissDisabled: Bool
  let detents: Set<PresentationDetent>
  @Environment(\.shakeToShipTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  func body(content: Content) -> some View {
    content
      .environment(\.feedbackCardPresented, true)
      .presentationDetents(detents).presentationDragIndicator(.visible)
      .presentationCornerRadius(theme.cornerRadius ?? 28)
      .presentationBackground(theme.background.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.regularMaterial))
      .interactiveDismissDisabled(dismissDisabled)
      .background(FeedbackOutsideDismiss(enabled: !dismissDisabled, dismiss: { dismiss() }))
  }
}

/// A native sheet owns its dimming view. Observe taps through its public container API.
private struct FeedbackOutsideDismiss: UIViewControllerRepresentable {
  let enabled: Bool
  let dismiss: () -> Void
  func makeUIViewController(context: Context) -> Controller { Controller() }
  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.enabled = enabled
    controller.close = dismiss
  }
  static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
    controller.removeGesture()
  }
  final class Controller: UIViewController, UIGestureRecognizerDelegate {
    var enabled = true
    var close: (() -> Void)?
    weak var sheet: UIPresentationController?
    var tap: UITapGestureRecognizer?
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      var owner: UIViewController? = parent
      while let current = owner {
        if let presentation = current.presentationController,
          let container = presentation.containerView {
          removeGesture()
          sheet = presentation
          let gesture = UITapGestureRecognizer(target: self, action: #selector(tapped))
          gesture.cancelsTouchesInView = false
          gesture.delegate = self
          container.addGestureRecognizer(gesture)
          tap = gesture
          break
        }
        owner = current.parent
      }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard enabled, let sheet, let container = sheet.containerView,
        sheet.presentedViewController.presentedViewController == nil else { return false }
      return !sheet.frameOfPresentedViewInContainerView.contains(touch.location(in: container))
    }
    @objc private func tapped() { if enabled { close?() } }
    func removeGesture() { if let tap { tap.view?.removeGestureRecognizer(tap) }; tap = nil }
  }
}

/// The recording remains unconfirmed unless either send action completes.
struct FeedbackReviewPresentation: View {
  let data: FeedbackComposerData
  let onSend: (FeedbackComposerResult) -> Void
  let onDiscard: () -> Void
  var onOptOut: (() -> Void)? = nil
  let onClose: () -> Void
  @State private var presented = false
  var body: some View {
    Group {
      if data.recorded != nil {
        Color.clear.ignoresSafeArea()
          .sheet(isPresented: $presented, onDismiss: onClose) {
            FeedbackPostCaptureCard(data: data, onSend: onSend, onDiscard: onDiscard, onOptOut: onOptOut)
          }
          .task { presented = true }
      } else {
        FeedbackComposer(data: data, onSend: onSend, onDiscard: onDiscard, onOptOut: onOptOut)
      }
    }
  }
}

struct FeedbackPostCaptureCard: View {
  let data: FeedbackComposerData
  let onSend: (FeedbackComposerResult) -> Void
  let onDiscard: () -> Void
  var onOptOut: (() -> Void)? = nil
  @State private var addingNote = false
  @State private var acted = false
  private var canCompose: Bool { !data.capabilities.intersection([.text, .photoLibrary]).isEmpty }
  var body: some View {
    Group {
      if addingNote {
        FeedbackSheet(title: data.capabilities.contains(.text) ? "Add a note" : "Add an attachment") {
          FeedbackComposer(data: data, onSend: send, onDiscard: onDiscard, onOptOut: onOptOut,
            inheritsHostStyle: true)
        } action: { EmptyView() }
      } else {
        ScrollView {
          FeedbackCard(symbol: "checkmark", title: "Thanks, got it",
            message: data.capabilities.contains(.text)
              ? "Add a note so we can fix it faster?" : "Your recording is ready to send.") {
            if canCompose {
              FeedbackCardAction(title: data.capabilities.contains(.text) ? "Add a note" : "Add an attachment") { addingNote = true }
              Button("Send as is") { sendUnchanged() }.buttonStyle(.plain).frame(minHeight: 44)
            } else {
              FeedbackCardAction(title: "Send as is") { sendUnchanged() }
            }
          }.disabled(acted)
        }.feedbackCardPresentation(dismissDisabled: acted)
      }
    }
  }
  private func sendUnchanged() {
    guard let recorded = data.recorded else { return }
    send(FeedbackComposerResult(media: [.recorded(recorded)], note: ""))
  }
  private func send(_ result: FeedbackComposerResult) {
    guard !acted else { return }
    acted = true
    onSend(result)
  }
}
#endif
