#if canImport(UIKit)
import SwiftUI

struct FeedbackLiveConversation: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.shakeToShipTheme) private var theme
  @Bindable var model: FeedbackHubModel
  var screenshot: Data?
  @State private var record: FeedbackConversationRecord?
  @State private var draft: FeedbackComposerData?
  @State private var busy = false
  @State private var submitting = false
  @State private var deliveryTask: Task<Void, Never>?
  @State private var preparing = false
  private var error: String? {
    get { model.error }
    nonmutating set { model.error = newValue }
  }
  @State private var reset = UUID()
  @State private var capturePending = false
  @State private var omitScreenshot = false
  @State private var confirmNew = false
  @State private var operation: Task<Void, Never>?

  private var messages: [FeedbackConversationMessage] {
    var result = (record?.snapshot?.messages ?? []).map { message in
      FeedbackConversationMessage(id: message.id, role: message.role == "user" ? .user : .assistant,
        text: message.text.isEmpty && message.sessionId != nil ? "Recording attached" : message.text,
        delivery: message.role == "user" ? .sent : nil, isTeamMessage: message.author == "team")
    }
    for (index, pending) in (record?.pendingMessages ?? []).enumerated() {
      let delivery: FeedbackConversationMessage.Delivery = index == 0 ? (busy ? .sending : .failed) : .queued
      if let index = result.firstIndex(where: { $0.id.lowercased() == pending.id.lowercased() }) {
        result[index].delivery = .waitingReply
        result[index].canRetry = !busy
      } else {
        result.append(.init(id: pending.id, role: .user,
          text: pending.text.isEmpty ? "Recording attached" : pending.text, delivery: delivery))
      }
    }
    if record?.snapshot?.replyError != nil {
      result.append(.init(id: "reply-unavailable", role: .notice,
        text: "Your message reached support. An automatic reply is unavailable. The team can still reply here."))
    }
    return result
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Menu {
          if (record?.reservedMessageCount ?? 0) >= 39, record?.pending == nil {
            Button("Move draft to new conversation", systemImage: "arrow.right") {
              operation?.cancel(); operation = Task { await startNew(preserveDraft: true) }
            }.disabled(busy || submitting || preparing)
          }
          if !messages.isEmpty {
            Button("New conversation", systemImage: "square.and.pencil") {
              if record?.pending != nil { confirmNew = true }
              else { operation?.cancel(); operation = Task { await startNew() } }
            }.disabled(busy || submitting)
          }
          if !model.supportConversations.isEmpty {
            Menu("Conversations") {
              if model.supportHistoryCursor != nil {
                Button("Load older conversations") { Task { await model.loadOlderSupportConversations() } }
              }
              ForEach(model.supportConversations) { conversation in
                Button {
                  operation?.cancel(); operation = Task { await selectConversation(conversation.id) }
                } label: {
                  Text((conversation.unread > 0 ? "● " : "") + (conversation.messages.first?.text.prefix(50).description ?? "Conversation"))
                }
              }
            }
          }
          Button("Cancel", role: .cancel) { dismiss() }
        } label: {
          Text("Support").font(.headline).foregroundStyle(theme.primaryText ?? .primary)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain).accessibilityLabel("Support")
        .accessibilityHint("Conversation options and close")
        .padding(.top, 24).padding(.bottom, 12)

        if capturePending {
          VStack(alignment: .leading, spacing: 8) {
            Text("Your recording could not be added. Your message is saved.")
            Button("Try adding recording again") { operation?.cancel(); operation = Task { await prepare() } }
            Button("Discard recording", role: .destructive) { discardCapture() }
          }.padding().disabled(busy || preparing)
        }
        if let draft {
          FeedbackReportConversation(messages: messages, data: draft, actionReset: reset,
            sending: submitting, error: error, onRead: markRead,
            deliveryPending: record?.pendingMessages.contains(where: { $0.id == draft.id }) == true,
            screenshot: omitScreenshot ? nil : screenshot,
            onRetry: { _ in startDelivery() },
            onSave: { try saveDraft($0, id: draft.id) },
            onSend: { value in operation?.cancel(); operation = Task { await submit(draft, value) } },
            onRecord: { value in
              guard !capturePending else { throw FeedbackHubError.storage }
              try saveDraft(value, id: draft.id)
              FeedbackManualTrigger.reportRecording = FeedbackReportRecording(store: model.draftStore, draftID: draft.id)
              FeedbackSDKPresentationMarker.requestWalkthrough()
            }, onDiscard: { discard(draft) }, onOptOut: model.config.onOptOut)
        } else {
          FeedbackConversationView(messages: messages, input: .constant(FeedbackConversationInput(isSending: busy, capabilities: [])), error: error, showsComposer: false,
            onSend: { _ in }, onRecord: {}, onAttach: {}, onRetry: { _ in startDelivery() }, onRemove: { _ in })
          if let error { Text(error).padding().accessibilityAddTraits(.updatesFrequently) }
          if record?.pending == nil && error != nil { Button("Try again") { operation?.cancel(); operation = Task { await load() } }.disabled(busy || submitting) }
        }
      }
      .background(theme.background ?? Color(uiColor: .systemGroupedBackground))
      .toolbar(.hidden, for: .navigationBar)
    }
    .feedbackTheme()
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .confirmationDialog("Start a new conversation?", isPresented: $confirmNew, titleVisibility: .visible) {
      Button("Start new conversation") { operation?.cancel(); operation = Task { await abandonPending() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Messages already sent remain with the team. Unsent messages and their recordings are removed.")
    }
    .onDisappear { operation?.cancel(); deliveryTask?.cancel(); model.visibleConversationID = nil }
    .background(FeedbackSDKPresentationMarker())
    .task {
      await load()
      if let id = model.supportReplyConversationID, record?.id != id { await selectConversation(id) }
      model.supportReplyConversationID = nil
    }
    .onChange(of: model.supportRevision) { _, _ in
      operation?.cancel(); operation = Task {
        if let latest = try? await model.client.loadConversation() { apply(latest) }
      }
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      while !Task.isCancelled {
        if let current = record, current.snapshot != nil {
          do {
            let refreshed = try await model.client.refreshConversation(current)
            try check()
            if record?.id == refreshed.id { apply(refreshed) }
          } catch is CancellationError { return }
          catch { /* Keep the draft and transcript available while offline. */ }
        }
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
      }
    }
    .onChange(of: model.revision) { _, _ in record = nil; draft = nil; dismiss() }
    .onChange(of: model.active) { _, active in if !active { record = nil; draft = nil; dismiss() } }
  }
  @State private var lastReadMessageID: String?
  private func markRead(_ id: String) {
    guard scenePhase == .active, id != lastReadMessageID,
      let current = record, let index = current.snapshot?.messages.firstIndex(where: { $0.id == id }) else { return }
    lastReadMessageID = id
    Task {
      do {
        try await model.client.readSupport(current.id, through: index + 1)
        if let summary = model.supportConversations.firstIndex(where: { $0.id == current.id }) {
          let oldUnread = model.supportConversations[summary].unread
          let through = max(model.supportConversations[summary].readThrough, index + 1)
          model.supportConversations[summary].readThrough = through
          model.supportConversations[summary].unread = model.supportConversations[summary].messages.enumerated()
            .filter { $0.element.role == "assistant" && $0.offset + 1 > through }.count
          model.supportUnreadTotal = max(0, model.supportUnreadTotal - oldUnread + model.supportConversations[summary].unread)
        }
      }
      catch { if lastReadMessageID == id { lastReadMessageID = nil } }
    }
  }
  private func check() throws {
    try Task.checkCancellation()
    guard model.active, model.identityGeneration == model.client.localGeneration else {
      throw FeedbackHubError.identityChanged
    }
  }
  private func save(_ value: FeedbackConversationRecord) async throws {
    try check()
    try await model.client.saveConversation(value)
    try check()
    record = value
  }
  private func load() async {
    do {
      try check()
      record = try await model.client.loadConversation()
      model.visibleConversationID = record?.id
      try check()
      if record?.pending != nil { startDelivery() } else { await prepare() }
    } catch is CancellationError { return }
    catch { self.error = "Could not load this conversation. Please try again." }
  }
  private func selectConversation(_ id: String) async {
    guard !submitting, !preparing, !capturePending, let previous = record, previous.id != id else { return }
    deliveryTask?.cancel()
    await deliveryTask?.value
    do {
      let selected = try await model.client.selectConversation(id)
      try check()
      do { try model.draftStore.selectConversation(from: previous.id, to: selected.id) }
      catch {
        try await model.client.saveConversation(previous)
        throw error
      }
      record = selected
      model.visibleConversationID = selected.id
      draft = nil
      reset = UUID()
      omitScreenshot = true
      await prepare()
      if selected.pending != nil { startDelivery() }
    } catch is CancellationError { return }
    catch { self.error = "Could not open this conversation. Please try again." }
  }
  private func startNew(preserveDraft: Bool = false) async {
    guard !busy, !submitting, record?.pending == nil else { return }
    // Keep an unsent message in its existing draft; only the destination conversation changes.
    do {
      let next = FeedbackConversationRecord(generation: model.identityGeneration, id: UUID().uuidString.lowercased())
      let movedDraft = preserveDraft ? try model.draftStore.load() : nil
      let previousID = record?.id
      if let previous = record { try model.draftStore.selectConversation(from: previous.id, to: next.id) }
      if let movedDraft { try model.draftStore.save(movedDraft) }
      // Only remove the old pointer after the new thread has a durable copy.
      if movedDraft != nil, let previousID {
        try model.draftStore.removeArchivedDraft(conversationID: previousID)
      }
      try await save(next)
      model.visibleConversationID = next.id
      draft = nil
      reset = UUID()
      await prepare()
    }
    catch is CancellationError { return }
    catch { self.error = "Could not start a conversation. Please try again." }
  }
  private func prepare() async {
    guard !preparing else { return }
    preparing = true
    defer { preparing = false }
    error = nil
    do {
      try check()
      try model.draftStore.clearMissingDirectoryRecord()
      var saved = try model.draftStore.load()
      // A crash may leave the draft pointer on any accepted queue item, not
      // only the message currently being uploaded. Never expose it for editing.
      if let accepted = saved, let pending = record?.pendingMessages.first(where: { $0.id == accepted.id }) {
        if pending.hasMedia, !writeFeedbackConfirmedMarker(in: accepted.directory) { throw FeedbackHubError.storage }
        try model.draftStore.clear(id: accepted.id)
        saved = nil
      }
      if var current = saved, let captureID = current.captureID {
        let capture = current.directory.deletingLastPathComponent().appendingPathComponent(captureID)
        if let bytes = try? Data(contentsOf: capture.appendingPathComponent("events.json")),
          let session = try? JSONDecoder().decode(FeedbackSession.self, from: bytes) {
          do { current = try await FeedbackReportRecording(store: model.draftStore, draftID: current.id)
            .completeCapture(in: capture, session: session) }
          catch is CancellationError { return }
          catch { self.error = "Could not add the recording. Try again or discard the recording." }
        } else {
          current.captureID = nil
          try model.draftStore.save(current)
          try? FileManager.default.removeItem(at: capture)
        }
        saved = current
      }
      if let old = saved, try FeedbackCaptureBinding.read(in: old.directory)?.purpose == .report {
        let sessions = try await model.client.ownedSessions()
        if FileManager.default.fileExists(atPath: old.directory.appendingPathComponent(feedbackConfirmedMarker).path) || sessions.contains(where: { $0.captureId == old.id }) {
          // Its immutable report purpose stays with the original uploader.
          try model.draftStore.clear(id: old.id)
          saved = nil
          omitScreenshot = true
        } else {
          try await model.client.bindCapture(in: old.directory, purpose: .feedback)
        }
      }
      if saved == nil {
        let id = UUID().uuidString.lowercased()
        let dir = model.draftStore.outboxRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try await model.client.bindCapture(in: dir, purpose: .feedback); try check() }
        catch { try? FileManager.default.removeItem(at: dir); throw error }
        // Text sends immediately. The attachment menu offers the captured screen explicitly.
        let value = FeedbackReportDraft(id: id, directory: dir, generation: model.identityGeneration)
        try model.draftStore.save(value)
        saved = value
      }
      guard let saved else { return }
      try check()
      capturePending = saved.captureID != nil
      draft = FeedbackComposerData(id: saved.id, dir: saved.directory, events: saved.events,
        capabilities: model.config.capabilities, showsTrail: false, initialMedia: saved.media,
        initialTitle: saved.title, initialNote: saved.note, maxAttachmentDuration: model.config.maxAttachmentDuration)
    } catch is CancellationError { return }
    catch { self.error = "Could not prepare your message. Please try again." }
  }
  private func saveDraft(_ value: FeedbackComposerDraftValue, id: String) throws {
    try check()
    guard var saved = try model.draftStore.load(), saved.id == id else { throw FeedbackHubError.storage }
    saved.update(value)
    try model.draftStore.save(saved)
  }
  private func discardCapture() {
    do {
      try check()
      guard var saved = try model.draftStore.load(), let id = saved.captureID else { return }
      saved.captureID = nil
      try model.draftStore.save(saved)
      try? FileManager.default.removeItem(at: saved.directory.deletingLastPathComponent().appendingPathComponent(id))
      capturePending = false; error = nil
    } catch { self.error = "Could not discard the recording." }
  }
  private func discard(_ value: FeedbackComposerData) {
    do {
      try check()
      guard let saved = try model.draftStore.load() else { return }
      try model.draftStore.clear(id: value.id)
      if let id = saved.captureID {
        try? FileManager.default.removeItem(at: value.dir.deletingLastPathComponent().appendingPathComponent(id))
      }
      try? FileManager.default.removeItem(at: value.dir)
      draft = nil
      omitScreenshot = true
      operation?.cancel(); operation = Task { await prepare() }
    } catch { self.error = "Could not discard your message."; reset = UUID() }
  }
  private func submit(_ data: FeedbackComposerData, _ value: FeedbackComposerResult) async {
    guard !submitting, !capturePending, var current = record else { return }
    submitting = true; error = nil
    do {
      try check()
      let encoded = try JSONSerialization.data(withJSONObject: ["app": model.config.app,
        "conversationId": current.id, "messageId": data.id, "text": value.note,
        "sessionId": "00000000-0000-4000-8000-000000000000"])
      guard value.note.utf16.count <= FeedbackConversationRecord.maxTextLength, encoded.count <= 8192 else {
        error = "Please shorten your message to 4,000 characters or fewer."
        submitting = false; reset = UUID(); return
      }
      guard current.reservedMessageCount < 39 else {
        error = "This conversation is full. Use Support to move your draft to a new conversation."
        submitting = false; reset = UUID(); return
      }
      if !value.media.isEmpty {
        // Unsent legacy drafts migrate in prepare; presigned report purposes never change.
        guard try FeedbackCaptureBinding.read(in: data.dir)?.purpose == .feedback else {
          throw FeedbackHubError.invalidResponse
        }
        guard persistComposedReport(value, in: data.dir) else { throw FeedbackHubError.storage }
        let session = FeedbackSession(session_id: data.id, app: model.config.app,
          build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
          started_at: ISO8601DateFormatter().string(from: Date()), user_ref: nil,
          events: value.media.contains(where: \.isRecorded) ? data.events : [])
        try JSONEncoder().encode(session).write(to: data.dir.appendingPathComponent("events.json"), options: .atomic)
      }
      let pending = FeedbackConversationRecord.Pending(id: data.id, text: value.note, hasMedia: !value.media.isEmpty)
      // The draft marker protects the files until the confirmed marker takes over.
      if !value.media.isEmpty {
        try Data().write(to: data.dir.appendingPathComponent(FeedbackConversationRecord.pendingMarker), options: .atomic)
      }
      let accepted = try await model.client.enqueueConversation(current, message: pending)
      try check()
      apply(accepted)
      if !value.media.isEmpty, !writeFeedbackConfirmedMarker(in: data.dir) { throw FeedbackHubError.storage }
      try model.draftStore.clear(id: data.id)
      // Prepare the next independent draft before network delivery starts.
      omitScreenshot = true
      await prepare()
    } catch is CancellationError { submitting = false; reset = UUID(); return }
    catch { self.error = "Could not save your message. Please try again." }
    submitting = false; reset = UUID()
    if record?.pending != nil { startDelivery() }
  }
  private func apply(_ value: FeedbackConversationRecord) {
    guard record?.id != value.id || (value.revision ?? 0) >= (record?.revision ?? 0) else { return }
    record = value
  }
  private func startDelivery() {
    guard !busy, record?.pending != nil else { return }
    busy = true
    deliveryTask = Task { await resume() }
  }
  private func resume() async {
    error = nil
    defer { busy = false }
    do {
      while var current = record, var pending = current.pending {
        try check()
        let dir = model.draftStore.outboxRoot.appendingPathComponent(pending.id)
        // Recover a crash after the pending record was written but before the draft was cleared.
        if (try? model.draftStore.load())?.id == pending.id {
          if pending.hasMedia, !writeFeedbackConfirmedMarker(in: dir) { throw FeedbackHubError.storage }
          try model.draftStore.clear(id: pending.id)
        }
        // Keep a separate editable draft while the accepted local message is delivered.
        omitScreenshot = true
        if !submitting && !preparing && (draft == nil || draft?.id == pending.id) {
          await prepare()
          if draft?.id == pending.id { draft = nil } // Preparation failed; retain the retry controls.
        }
        try check()
        if pending.hasMedia && !pending.uploaded {
          if FileManager.default.fileExists(atPath: dir.path) {
            guard writeFeedbackConfirmedMarker(in: dir) else { throw FeedbackHubError.storage }
            let uploader = FeedbackUploader(config: model.config, transport: FeedbackBackgroundUploads.transport,
              fileManager: .default, outboxRoot: model.draftStore.outboxRoot, hubClient: model.client)
            switch await uploader.upload(sessionId: pending.id) {
            case .uploaded: break
            case .retryableFailure: throw FeedbackHubError.storage
            case .recordingTooLarge:
              error = "The recording is too large. Start a new conversation with a shorter recording."
              return
            case .rejected:
              error = "This recording cannot be sent. Start a new conversation to continue."
              return
            }
          }
          try check()
          guard let session = try await model.client.ownedSessions().first(where: { $0.captureId == pending.id && $0.purpose == .feedback }) else {
            throw FeedbackHubError.storage
          }
          pending.sessionID = session.id
          pending.uploaded = true
          current = try await model.client.updateConversation(current, pending: pending)
          try check()
          apply(current)
        }
        // Bounded polling. A pending analysis remains retryable on the same message id.
        for attempt in 0..<4 {
          let snapshot = try await model.client.conversationTurn(current)
          current = try await model.client.updateConversation(current, pending: pending, snapshot: snapshot, completed: snapshot.acceptedMessageID == pending.id.lowercased() || !snapshot.pending)
          try check()
          apply(current)
          if snapshot.acceptedMessageID == pending.id.lowercased() || !snapshot.pending {
            if !pending.hasMedia { try? FileManager.default.removeItem(at: dir) }
            break
          }
          if attempt < 3 { try await Task.sleep(for: .seconds(10)) }
        }
        if record?.pending?.id == pending.id {
          error = "Your message is saved. The reply is not ready. Try again shortly."
          return
        }
      }
    } catch is CancellationError { return }
    catch {
      if case FeedbackHubError.http(429, _, let delay) = error {
        self.error = delay.map { "Please try again in \(Int($0)) seconds. Your message is saved." }
          ?? "Please try again later. Your message is saved."
      } else if case FeedbackHubError.http(_, let code, _) = error,
        ["message-id-conflict", "conversation-full", "recording-unavailable", "conversation-unavailable", "invalid-message"].contains(code) {
        self.error = "This message cannot be completed. Start a new conversation to continue."
      } else {
        self.error = "Could not complete delivery. Your message is saved. Try again or start a new conversation."
      }
    }
  }
  private func abandonPending() async {
    guard !busy, !submitting, let current = record, current.pending != nil else { return }
    do {
      try check()
      let directories = try current.pendingMessages.map { pending -> URL in
        let dir = model.draftStore.outboxRoot.appendingPathComponent(pending.id)
        guard UUID(uuidString: pending.id) != nil, model.draftStore.ownsDirectory(dir) else { throw FeedbackHubError.storage }
        if let binding = try FeedbackCaptureBinding.read(in: dir) {
          guard binding.scope == model.client.storage.scope, binding.generation == model.identityGeneration else { throw FeedbackHubError.identityChanged }
        }
        return dir
      }
      if let saved = try model.draftStore.load(), current.pendingMessages.contains(where: { $0.id == saved.id }) {
        try model.draftStore.clear(id: saved.id)
      }
      try await save(.init(generation: model.identityGeneration, id: UUID().uuidString.lowercased()))
      for dir in directories { try? FileManager.default.removeItem(at: dir) }
      omitScreenshot = true; error = nil
      await prepare()
    } catch is CancellationError { return }
    catch { self.error = "Could not start a new conversation. Please try again." }
  }
}
#endif
