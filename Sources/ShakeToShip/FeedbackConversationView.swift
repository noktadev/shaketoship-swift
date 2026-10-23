#if canImport(UIKit)
import SwiftUI

/// Native, headless conversation surface. The owner supplies persistence, delivery,
/// authorization, and real replies. The existing recorder remains the capture owner.
struct FeedbackConversationView: View {
  let messages: [FeedbackConversationMessage]
  @Binding var input: FeedbackConversationInput
  var error: String?
  var showsComposer = true
  var onDiscard: (() -> Void)?
  var onOptOut: (() -> Void)?
  var welcome = "What would you like to tell us?"
  var invitation = "A problem, an idea, or something we can improve."
  let onSend: () -> Void
  let onRecord: () -> Void
  let onAttach: () -> Void
  let onRetry: (String) -> Void
  let onRemove: (FeedbackMediaItem) -> Void

  @Environment(\.self) private var environment
  @Environment(\.shakeToShipTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  @FocusState private var editing: Bool
  @State private var selectedMedia: FeedbackMediaItem?

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
            Color.clear.frame(height: 1).id("conversation-end")
          }
          .padding()
          .frame(minHeight: viewport.size.height, alignment: .bottom)
        }
        .scrollDismissesKeyboard(.interactively)
        .defaultScrollAnchor(.bottom)
        .onChange(of: messages) { _, _ in reader.scrollTo("conversation-end", anchor: .bottom) }
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
    HStack(alignment: .top, spacing: 0) {
      if message.role == .user && !typeSize.isAccessibilitySize { Spacer(minLength: 28) }
      VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
        if !message.text.isEmpty {
          Text(verbatim: message.text)
            .textSelection(.enabled)
            .foregroundStyle(message.role == .user ? sentText : theme.primaryText ?? .primary)
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(message.role == .user
              ? accent
              : theme.surface ?? Color(uiColor: .secondarySystemGroupedBackground),
              in: RoundedRectangle(cornerRadius: 20))
        }
        ForEach(message.media) { item in attachment(item, removable: false) }
        if let delivery = message.delivery {
          Text(delivery.label)
            .font(.caption).foregroundStyle(theme.secondaryText ?? .secondary)
            .padding(.horizontal, 3)
            .accessibilityIdentifier("conversation-status-\(message.id)")
          if delivery == .failed || delivery == .waitingReply {
            Button(delivery == .waitingReply ? "Check for reply" : "Try sending again", systemImage: "arrow.clockwise") { onRetry(message.id) }
              .buttonStyle(.bordered).disabled(input.isSending || input.recordingRequested)
          }
        }
      }
      if message.role != .user && !typeSize.isAccessibilitySize { Spacer(minLength: 28) }
    }
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(message.role == .user ? "Your message" : message.role == .assistant ? "Support message" : "Update")
    .id(message.id)
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
              .disabled(input.isSending || input.recordingRequested)
              .accessibilityLabel("Message")
              .accessibilityIdentifier("conversation-message")
          } else {
            Text("Attach a photo or recording.").font(.callout)
              .foregroundStyle(theme.secondaryText ?? .secondary)
              .padding(12).frame(maxWidth: .infinity)
          }
          Button {
            guard input.canSend else { return }
            onSend()
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

      if input.recordingAvailable && input.capabilities.contains(.screenRecording) {
        Button {
          editing = false
          onRecord()
        } label: {
          Label("Show us", systemImage: "record.circle")
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain).foregroundStyle(theme.primaryText ?? .primary)
        .disabled(!input.canRecord)
        .accessibilityHint(input.recordingDescription)
        .accessibilityIdentifier("conversation-record")
      }
    }
    .padding(.horizontal).padding(.vertical, 12)
    .background(canvas)
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
#endif
