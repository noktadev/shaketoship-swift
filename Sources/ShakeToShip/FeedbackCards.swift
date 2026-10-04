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
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
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
    Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }
      .buttonStyle(.borderedProminent).controlSize(.regular)
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
  let editor: FeedbackRecordingEditor
  let onSend: (FeedbackComposerResult) -> Void
  let onDiscard: () -> Void
  var onOptOut: (() -> Void)? = nil
  let onClose: () -> Void
  @State private var presented = false
  var body: some View {
    Group {
      if data.recorded != nil {
        Color.clear.ignoresSafeArea()
          // Tear the overlay window down after SwiftUI finishes the sheet update. Closing it
          // inside onDismiss while the note keyboard is focused aborts with an exclusivity
          // conflict in SheetBridge.preferencesDidChange.
          .sheet(isPresented: $presented, onDismiss: { Task { @MainActor in onClose() } }) {
            FeedbackPostCaptureCard(data: data, editor: editor, onSend: onSend, onDiscard: onDiscard, onOptOut: onOptOut)
          }
          .task { presented = true }
      } else {
        FeedbackComposer(data: data, onSend: onSend, onDiscard: onDiscard, onOptOut: onOptOut)
      }
    }
  }
}

/// The recorded path: the existing preview, one optional note, and Send. The model writes the title.
struct FeedbackPostCaptureCard: View {
  let data: FeedbackComposerData
  let onSend: (FeedbackComposerResult) -> Void
  let onDiscard: () -> Void
  var onOptOut: (() -> Void)? = nil
  @State private var addingAttachment = false
  @State private var showingDetails = false
  @Environment(\.shakeToShipTheme) private var theme
  @State private var note: String
  @FocusState private var noteFocused: Bool
  @State private var previewing: FeedbackMediaItem?
  @State private var acted = false
  @State private var editor: FeedbackRecordingEditor
  @State private var exportTask: Task<Void, Never>?
  @State private var actionReset = UUID()
  @State private var detent: PresentationDetent = .large
  private var acceptsNote: Bool { FeedbackComposerRules.showsNoteField(capabilities: data.capabilities) }
  init(data: FeedbackComposerData, editor: FeedbackRecordingEditor, onSend: @escaping (FeedbackComposerResult) -> Void,
    onDiscard: @escaping () -> Void, onOptOut: (() -> Void)? = nil) {
    self.data = data
    self.onSend = onSend
    self.onDiscard = onDiscard
    self.onOptOut = onOptOut
    _note = State(initialValue: data.initialNote)
    _editor = State(initialValue: editor)
  }
  var body: some View {
    Group {
      if addingAttachment {
        FeedbackSheet(title: "Add an attachment") {
          FeedbackComposer(data: data.withInitialNote(note), onSend: export, onDiscard: onDiscard, onOptOut: onOptOut,
            actionReset: actionReset, inheritsHostStyle: true,
            formHeader: AnyView(Group { if let error = editor.error { Text(error).foregroundStyle(.red) } }))
        } action: { EmptyView() }
        .interactiveDismissDisabled(editor.preparing)
        .onDisappear { editor.pause(); exportTask?.cancel() }
      } else {
        NavigationStack {
          ScrollView {
            VStack(alignment: .leading, spacing: 24) {
              if let contextNote = data.contextNote {
                Text(contextNote).font(.subheadline).foregroundStyle(theme.secondaryText ?? .secondary).lineLimit(3)
              }
              FeedbackRecordingEditorView(editor: editor) {
                if let recorded = editor.source { previewing = .recorded(recorded) }
              }
              if !editor.loading, editor.source == nil {
                Button("Try again") { Task { await editor.load(data) } }.frame(minHeight: 44)
              }
              FeedbackTranscriptView(editor: editor)
              VStack(alignment: .leading, spacing: 12) {
                Text("We write the title").feedbackFont(.title3.weight(.semibold), inherit: false)
                  .feedbackPrimaryText().lineLimit(2)
                if acceptsNote {
                  HStack(alignment: .top) {
                    TextField("Add a note (optional)", text: $note,
                      prompt: Text("Add a note (optional)").foregroundStyle(theme.secondaryText ?? .secondary), axis: .vertical)
                      .lineLimit(2...4).textFieldStyle(.plain)
                      .foregroundStyle(theme.primaryText ?? .primary)
                      .accessibilityLabel("Note").focused($noteFocused)
                    if noteFocused {
                      Button("Done") { noteFocused = false }.frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("ShakeToShip.review.doneEditing")
                    }
                  }
                }
              }
              Divider()
              Button { noteFocused = false; showingDetails = true } label: {
                HStack(spacing: 12) {
                  Image(systemName: "info.circle").font(.body)
                  Text("Details").feedbackFont(.subheadline, inherit: false)
                  Spacer()
                  Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }.frame(minHeight: 44).contentShape(Rectangle())
              }.buttonStyle(.plain).foregroundStyle(theme.secondaryText ?? .secondary)
                .accessibilityIdentifier("ShakeToShip.review.details")
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 24)
              .disabled(acted || editor.preparing)
          }
          .background(theme.background ?? Color(uiColor: .systemBackground))
          .background(FeedbackNativeNavigationTheme())
          .navigationTitle("Review recording").navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Discard", role: .destructive) { act(onDiscard) }
                .accessibilityIdentifier("ShakeToShip.review.discard").disabled(acted || editor.preparing)
            }
          }
          .safeAreaInset(edge: .bottom) {
            Button(action: sendRecording) {
              HStack {
                if editor.preparing { ProgressView().tint(.white) }
                Text(editor.preparing ? "Preparing…" : data.sendLabel).fontWeight(.semibold).lineLimit(1)
              }.frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background(theme.accent ?? .accentColor, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 12)
              .background(theme.background ?? Color(uiColor: .systemBackground))
              .disabled(acted || editor.loading || editor.preparing || editor.source == nil)
              .accessibilityIdentifier("ShakeToShip.review.send")
          }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: note) { _, value in if !acted { FeedbackRecordedNoteDraft.save(value, in: data.dir) } }
        .task { await editor.load(data) }
        .onDisappear { editor.pause(); exportTask?.cancel() }
        .feedbackTheme()
        .feedbackCardPresentation(dismissDisabled: acted || editor.preparing, detents: [.medium, .large])
        .presentationDetents([.medium, .large], selection: $detent)
        .sheet(isPresented: $showingDetails) {
          NavigationStack {
            ScrollView {
              VStack(alignment: .leading, spacing: 32) {
                if let context = editor.context { FeedbackDevContextCard(context: context) }
                VStack(alignment: .leading, spacing: 16) {
                  Text("Timeline").feedbackFont(.headline, inherit: false)
                  ForEach(Array(FeedbackDevContext.timeline(events: editor.range.events(editor.events)).enumerated()), id: \.offset) { _, line in
                    let parts = line.split(separator: " ", maxSplits: 1)
                    HStack(alignment: .top, spacing: 16) {
                      Text(String(parts[0])).foregroundStyle(theme.secondaryText ?? .secondary)
                      Text(parts.count > 1 ? String(parts[1]) : "").lineLimit(3)
                    }.font(.system(.footnote, design: .monospaced)).fontDesign(.monospaced)
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                }.accessibilityIdentifier("ShakeToShip.review.timeline")
                Divider()
                FeedbackMicrophoneRow()
                if data.capabilities.contains(.photoLibrary) {
                  Button("Add an attachment", systemImage: "paperclip") { showingDetails = false; addingAttachment = true }
                    .frame(minHeight: 44)
                }
                if let onOptOut {
                  Button("Stop sending feedback", role: .destructive) { act(onOptOut) }
                    .feedbackFont(.footnote, inherit: false).frame(minHeight: 44)
                }
              }.padding(24).foregroundStyle(theme.primaryText ?? .primary)
            }.background(theme.background ?? Color(uiColor: .systemBackground))
              .background(FeedbackNativeNavigationTheme())
              .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
              .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
          }.feedbackTheme().presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $previewing) { item in
          FeedbackAttachmentViewer(items: [item], initialSelection: item.url, onRemove: nil)
        }
      }
    }
  }
  private func sendRecording() {
    guard let recorded = data.recorded else { return }
    guard !acted, !editor.preparing else { return }
    export(.recorded(recorded, note: note))
  }
  private func export(_ result: FeedbackComposerResult) {
    guard !acted, !editor.preparing else { return }
    // The ingest contract has no transcript field; the edited transcript rides in the note.
    let result = FeedbackComposerResult(media: result.media,
      note: FeedbackTranscript.note(result.note, transcript: editor.transcriptForSend))
    exportTask = Task {
      if await editor.prepare(data), !Task.isCancelled { send(result) }
      else { actionReset = UUID() }
    }
  }
  private func send(_ result: FeedbackComposerResult) { act { onSend(result) } }
  /// One decision per card: a second tap in the same frame must not send and discard.
  private func act(_ action: () -> Void) {
    guard !acted else { return }
    acted = true
    action()
  }
}
#endif
