#if canImport(UIKit)
import SwiftUI

/// Native report entry over the existing identity-scoped draft and upload pipeline.
/// Receipts remain upload receipts; this adapter does not fabricate agent replies.
struct FeedbackReportConversation: View {
  let messages: [FeedbackConversationMessage]
  let data: FeedbackComposerData
  let actionReset: UUID
  let sending: Bool
  let error: String?
  let screenshot: Data?
  let deliveryPending: Bool
  let onRead: (String) -> Void
  let onRetry: (String) -> Void
  let onSave: (FeedbackComposerDraftValue) throws -> Void
  let onSend: (FeedbackComposerResult) -> Void
  let onRecord: (FeedbackComposerDraftValue) throws -> Void
  let onDiscard: () -> Void
  let onOptOut: (() -> Void)?
  @State private var input: FeedbackConversationInput
  @State private var showPicker = false
  @State private var localError: String?
  @State private var acted = false
  @State private var submittedInput: FeedbackConversationInput?

  init(messages: [FeedbackConversationMessage] = [], data: FeedbackComposerData, actionReset: UUID, sending: Bool, error: String?,
    onRead: @escaping (String) -> Void = { _ in }, deliveryPending: Bool = false, screenshot: Data? = nil, onRetry: @escaping (String) -> Void = { _ in },
    onSave: @escaping (FeedbackComposerDraftValue) throws -> Void,
    onSend: @escaping (FeedbackComposerResult) -> Void,
    onRecord: @escaping (FeedbackComposerDraftValue) throws -> Void,
    onDiscard: @escaping () -> Void, onOptOut: (() -> Void)?) {
    self.onRead = onRead
    self.messages = messages
    self.screenshot = screenshot
    self.deliveryPending = deliveryPending; self.onRetry = onRetry
    self.actionReset = actionReset
    self.data = data; self.sending = sending; self.error = error
    self.onSave = onSave; self.onSend = onSend; self.onRecord = onRecord
    self.onDiscard = onDiscard; self.onOptOut = onOptOut
    _input = State(initialValue: FeedbackConversationInput(
      text: [data.initialTitle, data.initialNote].filter { !$0.isEmpty }.joined(separator: "\n\n"),
      media: data.initialMedia, isSending: sending, deliveryPending: deliveryPending, capabilities: data.capabilities,
      recordingAvailable: FeedbackManualTrigger.isRecordingAvailable))
  }

  private var draft: FeedbackComposerDraftValue {
    FeedbackComposerDraftValue(title: "", note: input.text, media: input.media)
  }

  private var screenshotAction: (() -> Void)? {
    guard screenshot != nil,
      !input.media.contains(where: { $0.url.lastPathComponent == "report-screenshot.jpg" }) else { return nil }
    return { attachScreenshot() }
  }

  var body: some View {
    FeedbackConversationView(messages: messages, input: $input, error: localError ?? error, onRead: onRead,
      onDiscard: onDiscard, onOptOut: onOptOut,
      onScreenshot: screenshotAction,
      welcome: "What would you like to tell us?",
      invitation: "A problem, an idea, or something we can improve.",
      onSend: { submitted in
        guard !acted, submitted.canSend else { return }
        do {
          try onSave(FeedbackComposerDraftValue(title: "", note: submitted.text, media: submitted.media))
          let result = FeedbackComposerResult(media: submitted.media,
            note: submitted.capabilities.contains(.text) ? submitted.text : "")
          submittedInput = submitted
          acted = true
          input.text = ""
          input.media = []
          input.isSending = true
          onSend(result)
        } catch { localError = "Could not save your message. Please try again." }
      }, onRecord: {
        guard !acted, input.canRecord else { return }
        do { try onRecord(draft); acted = true; input.recordingRequested = true }
        catch { localError = "Could not start recording. Please try again." }
      }, onAttach: { showPicker = true }, onRetry: onRetry, onRemove: remove)
      .onChange(of: input.text) { _, _ in
        guard !acted else { return }
        do { try onSave(draft); localError = nil }
        catch { localError = "Could not save your message. Please try again." }
      }
      .onChange(of: data.id) { _, _ in
        let nextText = submittedInput == nil
          ? [data.initialTitle, data.initialNote].filter { !$0.isEmpty }.joined(separator: "\n\n")
          : input.text
        input = FeedbackConversationInput(text: nextText, media: data.initialMedia,
          isSending: sending, deliveryPending: deliveryPending, capabilities: data.capabilities,
          recordingAvailable: FeedbackManualTrigger.isRecordingAvailable)
        submittedInput = nil
        acted = false
        do { try onSave(draft); localError = nil }
        catch { localError = "Could not save your message. Please try again." }
      }
      .onChange(of: data.initialMedia) { _, media in
        if submittedInput == nil { input.media = media }
      }
      .onChange(of: actionReset) { _, _ in
        if let submitted = submittedInput, !deliveryPending {
          let nextText = input.text
          input = submitted
          if !nextText.isEmpty { input.text += "\n\n" + nextText }
          submittedInput = nil
        }
        acted = submittedInput != nil
        input.isSending = sending
        input.recordingRequested = false
      }
      .onChange(of: sending) { _, value in
        input.isSending = value
      }
      .onChange(of: deliveryPending) { _, value in input.deliveryPending = value }
      .onAppear { input.recordingAvailable = FeedbackManualTrigger.isRecordingAvailable }
      .sheet(isPresented: $showPicker) {
        FeedbackPhotoPicker(
          selectionLimit: FeedbackComposerRules.remainingSelectionLimit(mediaCount: input.media.count),
          stagingDirectory: data.stagingDirectory, maxAttachmentDuration: data.maxAttachmentDuration,
          existingCount: input.media.count,
          existingBytes: input.media.filter { !$0.isRecorded }.reduce(0) {
            $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
          }) { outcome in
            showPicker = false
            let updated = input.media + outcome.accepted
            do {
              try onSave(FeedbackComposerDraftValue(title: "", note: input.text, media: updated))
              input.media = updated
              localError = outcome.rejection?.message
            } catch {
              for item in outcome.accepted { try? FileManager.default.removeItem(at: item.url) }
              localError = "Could not save your attachments. Please try again."
            }
          }.ignoresSafeArea()
      }
  }

  private func attachScreenshot() {
    guard !acted, !sending,
      input.media.count < FeedbackAttachmentBounds.maxItems else { return }
    do {
      let media = try FeedbackReportScreenshot.stage(screenshot, in: data.dir)
      let updated = input.media + media
      try onSave(FeedbackComposerDraftValue(title: "", note: input.text, media: updated))
      input.media = updated
      localError = nil
    } catch { localError = "Could not add the screenshot. Please try again." }
  }

  private func remove(_ item: FeedbackMediaItem) {
    guard !acted, !sending else { return }
    let updated = input.media.filter { $0.id != item.id }
    do {
      try onSave(FeedbackComposerDraftValue(title: "", note: input.text, media: updated))
      input.media = updated
      try? FileManager.default.removeItem(at: item.url)
      localError = nil
    } catch { localError = "Could not remove this attachment. Please try again." }
  }
}
#endif
