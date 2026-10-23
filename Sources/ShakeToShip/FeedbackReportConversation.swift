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
  let onSave: (FeedbackComposerDraftValue) throws -> Void
  let onSend: (FeedbackComposerResult) -> Void
  let onRecord: (FeedbackComposerDraftValue) throws -> Void
  let onDiscard: () -> Void
  let onOptOut: (() -> Void)?
  @State private var input: FeedbackConversationInput
  @State private var showPicker = false
  @State private var localError: String?
  @State private var acted = false

  init(messages: [FeedbackConversationMessage] = [], data: FeedbackComposerData, actionReset: UUID, sending: Bool, error: String?,
    onSave: @escaping (FeedbackComposerDraftValue) throws -> Void,
    onSend: @escaping (FeedbackComposerResult) -> Void,
    onRecord: @escaping (FeedbackComposerDraftValue) throws -> Void,
    onDiscard: @escaping () -> Void, onOptOut: (() -> Void)?) {
    self.messages = messages
    self.actionReset = actionReset
    self.data = data; self.sending = sending; self.error = error
    self.onSave = onSave; self.onSend = onSend; self.onRecord = onRecord
    self.onDiscard = onDiscard; self.onOptOut = onOptOut
    _input = State(initialValue: FeedbackConversationInput(
      text: [data.initialTitle, data.initialNote].filter { !$0.isEmpty }.joined(separator: "\n\n"),
      media: data.initialMedia, capabilities: data.capabilities,
      recordingAvailable: FeedbackManualTrigger.isRecordingAvailable))
  }

  private var draft: FeedbackComposerDraftValue {
    FeedbackComposerDraftValue(title: "", note: input.text, media: input.media)
  }

  var body: some View {
    FeedbackConversationView(messages: messages, input: $input, error: localError ?? error,
      onDiscard: onDiscard, onOptOut: onOptOut,
      welcome: "What would you like to tell us?",
      invitation: "A problem, an idea, or something we can improve.",
      onSend: {
        guard !acted, input.canSend else { return }
        do {
          try onSave(draft)
          acted = true
          input.isSending = true
          onSend(FeedbackComposerResult(media: input.media,
            note: input.capabilities.contains(.text) ? input.text : ""))
        } catch { localError = "Could not save your message. Please try again." }
      }, onRecord: {
        guard !acted, input.canRecord else { return }
        do { try onRecord(draft); acted = true; input.recordingRequested = true }
        catch { localError = "Could not start recording. Please try again." }
      }, onAttach: { showPicker = true }, onRetry: { _ in }, onRemove: remove)
      .disabled(acted && !sending)
      .onChange(of: input.text) { _, _ in
        guard !acted else { return }
        do { try onSave(draft); localError = nil }
        catch { localError = "Could not save your message. Please try again." }
      }
      .onChange(of: actionReset) { _, _ in
        acted = false
        input.isSending = false
        input.recordingRequested = false
      }
      .onChange(of: sending) { _, value in
        input.isSending = value

      }
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
