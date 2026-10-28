#if canImport(UIKit)
import SwiftUI

/// Native, headless conversation surface. The owner supplies persistence, delivery,
/// authorization, and real replies. The existing recorder remains the capture owner.
struct FeedbackConversationView: View {
  let messages: [FeedbackConversationMessage]
  @Binding var input: FeedbackConversationInput
  var error: String?
  var showsComposer = true
  var onRead: (String) -> Void = { _ in }
  var onDiscard: (() -> Void)?
  var onOptOut: (() -> Void)?
  var onScreenshot: (() -> Void)?
  var welcome = "What would you like to tell us?"
  var invitation = "A problem, an idea, or something we can improve."
  let onSend: (FeedbackConversationInput) -> Void
  let onRecord: () -> Void
  let onAttach: () -> Void
  let onRetry: (String) -> Void
  let onRemove: (FeedbackMediaItem) -> Void

  @Environment(\.openURL) private var openURL
  @Environment(\.self) private var environment
  @Environment(\.shakeToShipTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  @FocusState private var editing: Bool
  @State private var atBottom = true
  @State private var hasNewReply = false
  @State private var selectedMedia: FeedbackMediaItem?
  @State private var textBridge = ConversationTextBridge()

  private var accent: Color { theme.accent ?? Color(red: 0.78, green: 0.22, blue: 0.0) }
  private var sentText: Color {
    let fill = accent.resolve(in: environment)
    let base = canvas.resolve(in: environment)
    func channel(_ value: Float, _ background: Float) -> UInt32 {
      UInt32((min(1, max(0, value * fill.opacity + background * (1 - fill.opacity))) * 255).rounded())
    }
    let rgb = FeedbackPromptButtonColors.RGB(
      (channel(fill.red, base.red) << 16) | (channel(fill.green, base.green) << 8) | channel(fill.blue, base.blue))
    return FeedbackPromptButtonColors.contrastRatio(rgb, .init(0xFFFFFF)) >= 4.5 ? .white : .black
  }
  private var canvas: Color { theme.background ?? Color(uiColor: .systemGroupedBackground) }

  private var allMedia: [FeedbackMediaItem] {
    var seen = Set<URL>()
    return (messages.flatMap(\.media) + input.media).filter { seen.insert($0.id).inserted }
  }

  var body: some View {
    ScrollViewReader { reader in
      GeometryReader { viewport in
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            if messages.isEmpty {
              VStack(alignment: .leading, spacing: 6) {
                Text(welcome).font(.body.weight(.medium)).feedbackPrimaryText()
                Text(invitation).font(.subheadline)
                  .foregroundStyle(theme.secondaryText ?? .secondary)
              }
              .padding(16)
              .background(theme.surface ?? Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20))
              .padding(.trailing, typeSize.isAccessibilitySize ? 0 : 28)
            }
            ForEach(messages) { message in messageRow(message) }
            if showsComposer && !messages.contains(where: { $0.role == .user }) { quickReplies }
            Color.clear.frame(height: 1).id("conversation-end")
              .background(GeometryReader { proxy in
                Color.clear.preference(key: ConversationFrames.self, value: ["conversation-end": proxy.frame(in: .named("conversation-timeline"))])
              })
          }
          .padding()
          .frame(minHeight: viewport.size.height, alignment: .bottom)
        }
        .coordinateSpace(name: "conversation-timeline")
        .onPreferenceChange(ConversationFrames.self) { frames in
          if let end = frames["conversation-end"] {
            atBottom = end.maxY <= viewport.size.height + 24
            if atBottom { hasNewReply = false }
          }
          if let visible = messages.last(where: { message in
            guard message.role == .assistant, let frame = frames[message.id] else { return false }
            return frame.minY >= 0 && frame.maxY <= viewport.size.height
          }) { onRead(visible.id) }
        }
        .overlay(alignment: .bottom) {
          if hasNewReply {
            Button("New reply") { reader.scrollTo("conversation-end", anchor: .bottom); hasNewReply = false }
              .buttonStyle(.borderedProminent).padding(8)
          }
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .onChange(of: messages) { old, new in
          if atBottom || new.last?.role == .user { reader.scrollTo("conversation-end", anchor: .bottom) }
          else if old.last?.id != new.last?.id { hasNewReply = true }
        }
        .onChange(of: input.text) { _, _ in
          if editing { reader.scrollTo("conversation-end", anchor: .bottom) }
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { if showsComposer { composer } }
      .background(canvas)
      .navigationBarTitleDisplayMode(.inline)
      .feedbackTheme()
      .onChange(of: error) { _, value in
        if let value { AccessibilityNotification.Announcement(value).post() }
      }
      .fullScreenCover(item: $selectedMedia) { item in
        FeedbackAttachmentViewer(items: allMedia, initialSelection: item.id,
          onRemove: input.media.contains(where: { $0.id == item.id }) && !input.isSending ? { item in
            onRemove(item)
            return !input.media.contains(where: { $0.id == item.id })
          } : nil)
      }
    }
  }

  private func messageRow(_ message: FeedbackConversationMessage) -> some View {
    let content = message.content
    return HStack(alignment: .top, spacing: 0) {
      if message.role == .user && !typeSize.isAccessibilitySize { Spacer(minLength: 28) }
      VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
        if !content.text.isEmpty {
          HStack(alignment: .bottom, spacing: 4) {
            Text(verbatim: content.text).textSelection(.enabled)
            if message.role == .user { deliveryControl(message) }
          }
            .foregroundStyle(message.role == .user ? sentText : theme.primaryText ?? .primary)
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(message.role == .user
              ? accent
              : theme.surface ?? Color(uiColor: .secondarySystemGroupedBackground),
              in: RoundedRectangle(cornerRadius: 20))
        }
        if message.role == .assistant {
          ForEach(content.actions) { action in
            messageAction(action, messageID: message.id, active: showsComposer && message.id == messages.last?.id)
          }
        }
        ForEach(message.media) { item in attachment(item, removable: false) }
        if content.text.isEmpty && message.role == .user { deliveryControl(message) }
      }
      if message.role != .user && !typeSize.isAccessibilitySize { Spacer(minLength: 28) }
    }
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(message.role == .user ? "Your message" : message.role == .assistant ? "Support message" : "Update")
    .id(message.id)
    .background(GeometryReader { proxy in
      Color.clear.preference(key: ConversationFrames.self, value: [message.id: proxy.frame(in: .named("conversation-timeline"))])
    })
  }

  /// Space stays reserved across delivery transitions. Normal delivery is silent.
  private func deliveryControl(_ message: FeedbackConversationMessage) -> some View {
    let needsAction = message.delivery == .failed || message.delivery == .waitingReply
    return Color.clear.frame(width: 44, height: 20).overlay {
    Button { onRetry(message.id) } label: {
      Image(systemName: message.delivery == .failed ? "exclamationmark.circle" : "arrow.clockwise")
        .font(.body)
        .frame(width: 44, height: 44)
        .opacity(needsAction ? 1 : 0)
    }
    .buttonStyle(.plain)
    .disabled(!needsAction || !message.canRetry || input.recordingRequested)
    .accessibilityHidden(!needsAction)
    .accessibilityLabel(message.delivery == .waitingReply ? "Check for reply" : "Try sending again")
    .accessibilityHint(message.delivery?.label ?? "")
    .accessibilityIdentifier("conversation-status-\(message.id)")
    }
  }

  private var composer: some View {
    VStack(spacing: 12) {
      if let error {
        Label(error, systemImage: "exclamationmark.circle")
          .font(.callout).foregroundStyle(theme.primaryText ?? .primary)
          .accessibilityIdentifier("conversation-error")
      }
      if !input.media.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 12) {
            ForEach(input.media) { item in attachment(item, removable: true) }
          }
        }
      }
      HStack(alignment: .bottom, spacing: 10) {
        Menu {
          if input.recordingAvailable && input.capabilities.contains(.screenRecording) {
            Button("Record your screen", systemImage: "record.circle") {
              editing = false
              onRecord()
            }
            .disabled(!input.canRecord)
            .accessibilityIdentifier("conversation-record-menu")
          }
          if let onScreenshot {
            Button("Attach current screen", systemImage: "rectangle.dashed", action: onScreenshot)
              .disabled(input.isSending ||
                input.media.count >= FeedbackAttachmentBounds.maxItems)
          }
          if input.capabilities.contains(.photoLibrary) {
            Button("Attach a photo or video", systemImage: "photo.on.rectangle", action: onAttach)
              .disabled(!input.canAttach)
          }
          if let onDiscard { Button("Discard message", role: .destructive, action: onDiscard) }
          if let onOptOut { Button("Stop asking for feedback", action: onOptOut) }
        } label: {
          Image(systemName: "photo.on.rectangle")
            .font(.title3).foregroundStyle(theme.primaryText ?? .primary)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(input.isSending || input.recordingRequested)
        .accessibilityLabel("Attachments and message options")
        .accessibilityIdentifier("conversation-attach")
        HStack(alignment: .bottom, spacing: 0) {
          if input.capabilities.contains(.text) {
            TextField("Message", text: $input.text, axis: .vertical)
              .lineLimit(1...5).textFieldStyle(.plain)
              .padding(.leading, 15).padding(.vertical, 11)
              .focused($editing)
              .disabled(input.recordingRequested)
              .accessibilityLabel("Message")
              .accessibilityIdentifier("conversation-message")
              .background(ConversationTextAnchor(bridge: textBridge))
          } else {
            Text("Attach a photo or recording.").font(.callout)
              .foregroundStyle(theme.secondaryText ?? .secondary)
              .padding(12).frame(maxWidth: .infinity)
          }
          Button {
            var submitted = input
            if let text = textBridge.commitText() { submitted.text = text }
            guard submitted.canSend else { return }
            onSend(submitted)
          } label: {
            if input.isSending { ProgressView() }
            else { Image(systemName: "arrow.up.circle.fill").font(.title) }
          }
          .buttonStyle(.plain).foregroundStyle(accent)
          .frame(width: 44, height: 44)
          .disabled(!input.canSend)
          .opacity(input.canSend || input.isSending ? 1 : 0)
          .accessibilityHidden(!input.canSend && !input.isSending)
          .accessibilityLabel(input.isSending ? "Sending" : "Send message")
          .accessibilityIdentifier("conversation-send")
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
      }
    }
    .padding(.horizontal).padding(.vertical, 12)
    .background(canvas)
  }

  @ViewBuilder private func messageAction(_ action: FeedbackConversationAction, messageID: String, active: Bool) -> some View {
    switch action.kind {
    case .link(let url):
      Button {
        openURL(url)
      } label: {
        VStack(alignment: .leading, spacing: 3) {
          Label(action.label, systemImage: "arrow.up.right")
          Text(url.host ?? "").font(.caption).foregroundStyle(.secondary)
        }
      }
      .buttonStyle(QuickReplyButtonStyle(canvas: canvas, outline: accent, text: theme.primaryText ?? .primary))
      .accessibilityHint("Opens " + (url.host ?? "a website"))
      .accessibilityIdentifier("conversation-action-" + messageID + "-" + action.id)
    case .reply(let text):
      Button(action.label) {
        appendReply(text)
      }
      .buttonStyle(QuickReplyButtonStyle(canvas: canvas, outline: accent, text: theme.primaryText ?? .primary))
      .disabled(!active || input.recordingRequested || !input.capabilities.contains(.text))
      .accessibilityHint(active ? "Adds text to your message. You can edit it before sending." : "This option belongs to an earlier message.")
      .accessibilityIdentifier("conversation-action-" + messageID + "-" + action.id)
    case .recordScreen:
      Button(action.label, systemImage: "record.circle") {
        editing = false
        onRecord()
      }
      .buttonStyle(QuickReplyButtonStyle(canvas: canvas, outline: accent, text: theme.primaryText ?? .primary))
      .disabled(!active || !input.canRecord)
      .accessibilityHint(active ? input.recordingDescription : "This option belongs to an earlier message.")
      .accessibilityIdentifier("conversation-action-" + messageID + "-" + action.id)
    }
  }

  @ViewBuilder private var quickReplies: some View {
    if input.capabilities.contains(.text) ||
      (input.recordingAvailable && input.capabilities.contains(.screenRecording)) {
      VStack(alignment: .trailing, spacing: 8) {
        if input.capabilities.contains(.text) {
          quickReply("I found a problem", id: "problem")
          quickReply("I have an idea", id: "idea")
        }
        if input.recordingAvailable && input.capabilities.contains(.screenRecording) {
          Button {
            editing = false
            onRecord()
          } label: {
            Label("Let me show you", systemImage: "record.circle")
          }
          .disabled(!input.canRecord)
          .accessibilityHint(input.recordingDescription)
          .accessibilityIdentifier("conversation-record")
        }
      }
      .font(.subheadline)
      .multilineTextAlignment(.center)
      .buttonStyle(QuickReplyButtonStyle(canvas: canvas, outline: accent,
        text: theme.primaryText ?? .primary))
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func quickReply(_ text: String, id: String) -> some View {
    Button {
      appendReply(text + ": ")
    } label: {
      Text(text)
    }
    .disabled(input.recordingRequested)
    .accessibilityHint("Adds text to your message. You can edit it before sending.")
    .accessibilityIdentifier("conversation-quick-" + id)
  }

  private func appendReply(_ text: String) {
    let current = textBridge.commitText() ?? input.text
    let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
    input.text = current + separator + text
    editing = true
  }

  private struct QuickReplyButtonStyle: ButtonStyle {
    let canvas: Color
    let outline: Color
    let text: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .foregroundStyle(text)
        .background(canvas, in: Capsule())
        .overlay(Capsule().strokeBorder(outline.opacity(0.5), lineWidth: 1))
        .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
    }
  }

  private func attachment(_ item: FeedbackMediaItem, removable: Bool) -> some View {
    HStack(spacing: 8) {
      Button { selectedMedia = item } label: {
        HStack(spacing: 8) {
          FeedbackMediaThumbnail(item: item)
            .frame(width: 40, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
          Text(item.isRecorded ? "Screen recording" : item.kind == .video ? "Video" : "Photo")
            .font(.caption).foregroundStyle(theme.primaryText ?? .primary)
        }
      }.buttonStyle(.plain)
        .accessibilityIdentifier("ShakeToShip.attachment.thumbnail.\(item.kind == .video ? "video" : "image")")
      if removable {
        Button { onRemove(item) } label: {
          Image(systemName: "xmark.circle.fill").font(.body)
            .foregroundStyle(.secondary).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove attachment: \(item.isRecorded ? "screen recording" : item.kind == .video ? "video" : "photo") \((input.media.firstIndex(where: { $0.id == item.id }) ?? 0) + 1)")
        .disabled(input.isSending || input.recordingRequested)
      }
    }
    .padding(6)
    .background(theme.surface ?? Color(uiColor: .secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 14))
  }
}
private struct ConversationFrames: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

/// Reads the focused native editor at the explicit Send boundary. SwiftUI's
/// binding can still contain the preceding edit while UIKit displays newer text.
/// Committing marked text keeps the keyboard and first responder in place.
@MainActor private final class ConversationTextBridge {
  weak var anchor: UIView?

  func commitText() -> String? {
    var ancestor = anchor?.superview
    // Never search the host window. Require this field's identifier as well as
    // native focus, and bound the search to nearby composer containers.
    for _ in 0..<3 {
      guard let view = ancestor, !(view is UIWindow) else { return nil }
      if let editor = focusedEditor(in: view) {
        editor.unmarkText()
        guard let range = editor.textRange(from: editor.beginningOfDocument, to: editor.endOfDocument) else { return nil }
        return editor.text(in: range)
      }
      ancestor = view.superview
    }
    return nil
  }

  private func focusedEditor(in view: UIView) -> (any UITextInput)? {
    if view.accessibilityIdentifier == "conversation-message", view.isFirstResponder,
      let editor = view as? any UITextInput { return editor }
    for child in view.subviews {
      if let editor = focusedEditor(in: child) { return editor }
    }
    return nil
  }
}

private struct ConversationTextAnchor: UIViewRepresentable {
  let bridge: ConversationTextBridge
  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    bridge.anchor = view
    return view
  }
  func updateUIView(_ view: UIView, context: Context) { bridge.anchor = view }
}
#endif
