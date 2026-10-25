#if canImport(UIKit)
import SwiftUI

struct FeedbackLiveConversation: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.shakeToShipTheme) private var theme
  @Bindable var model: FeedbackHubModel
  var screenshot: Data?
  @State private var record: FeedbackConversationRecord?
  @State private var draft: FeedbackComposerData?
  @State private var busy = false
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
        delivery: message.role == "user" ? .sent : nil)
    }
    if let pending = record?.pending {
      let delivery: FeedbackConversationMessage.Delivery = busy ? .sending : .failed
      if let index = result.firstIndex(where: { $0.id.lowercased() == pending.id.lowercased() }) {
        result[index].delivery = .waitingReply
      } else {
        result.append(.init(id: pending.id, role: .user,
          text: pending.text.isEmpty ? "Recording attached" : pending.text, delivery: delivery))
      }
    }
    return result
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Menu {
          if !messages.isEmpty {
            Button("New conversation", systemImage: "square.and.pencil") {
              if record?.pending != nil { confirmNew = true }
              else { operation = Task { await startNew() } }
            }.disabled(busy)
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
            Button("Try adding recording again") { operation = Task { await prepare() } }
            Button("Discard recording", role: .destructive) { discardCapture() }
          }.padding().disabled(busy || preparing)
        }
        if let draft {
          FeedbackReportConversation(messages: messages, data: draft, actionReset: reset,
            sending: busy, error: error,
            deliveryPending: record?.pending != nil,
            screenshot: omitScreenshot ? nil : screenshot,
            onRetry: { _ in operation = Task { await resume() } },
            onSave: { try saveDraft($0, id: draft.id) },
            onSend: { value in operation = Task { await submit(draft, value) } },
            onRecord: { value in
              guard !capturePending else { throw FeedbackHubError.storage }
              try saveDraft(value, id: draft.id)
              FeedbackManualTrigger.reportRecording = FeedbackReportRecording(store: model.draftStore, draftID: draft.id)
              FeedbackSDKPresentationMarker.requestWalkthrough()
            }, onDiscard: { discard(draft) }, onOptOut: model.config.onOptOut)
        } else {
          FeedbackConversationView(messages: messages, input: .constant(FeedbackConversationInput(isSending: busy, capabilities: [])), error: error, showsComposer: false,
            onSend: {}, onRecord: {}, onAttach: {}, onRetry: { _ in operation = Task { await resume() } }, onRemove: { _ in })
          if let error { Text(error).padding().accessibilityAddTraits(.updatesFrequently) }
          if record?.pending == nil && error != nil { Button("Try again") { operation = Task { await load() } }.disabled(busy) }
        }
      }
      .background(theme.background ?? Color(uiColor: .systemGroupedBackground))
      .toolbar(.hidden, for: .navigationBar)
    }
    .feedbackTheme()
    .presentationDetents([.large]).presentationDragIndicator(.visible)
    .confirmationDialog("Start a new conversation?", isPresented: $confirmNew, titleVisibility: .visible) {
      Button("Start new conversation") { operation = Task { await abandonPending() } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Messages already sent remain with the team. Any unsent recording for this message is removed.")
    }
    .onDisappear { operation?.cancel() }
    .background(FeedbackSDKPresentationMarker())
    .task { await load() }
    .onChange(of: model.revision) { _, _ in record = nil; draft = nil; dismiss() }
    .onChange(of: model.active) { _, active in if !active { record = nil; draft = nil; dismiss() } }
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
      try check()
      if record?.pending != nil { await resume() } else { await prepare() }
    } catch is CancellationError { return }
    catch { self.error = "Could not load this conversation. Please try again." }
  }
  private func startNew() async {
    guard !busy, record?.pending == nil else { return }
    // Keep an unsent message in its existing draft; only the destination conversation changes.
    do { try await save(.init(generation: model.identityGeneration, id: UUID().uuidString.lowercased())) }
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
      operation = Task { await prepare() }
    } catch { self.error = "Could not discard your message."; reset = UUID() }
  }
  private func submit(_ data: FeedbackComposerData, _ value: FeedbackComposerResult) async {
    guard !busy, !capturePending, var current = record, current.pending == nil else { return }
    busy = true; error = nil
    do {
      try check()
      let encoded = try JSONSerialization.data(withJSONObject: ["app": model.config.app,
        "conversationId": current.id, "messageId": data.id, "text": value.note,
        "sessionId": "00000000-0000-4000-8000-000000000000"])
      guard value.note.utf16.count <= FeedbackConversationRecord.maxTextLength, encoded.count <= 8192 else {
        error = "Please shorten your message to 4,000 characters or fewer."
        busy = false; reset = UUID(); return
      }
      if (current.snapshot?.messages.count ?? 0) >= 39 {
        current = .init(generation: model.identityGeneration, id: UUID().uuidString.lowercased())
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
      current.pending = .init(id: data.id, text: value.note, hasMedia: !value.media.isEmpty)
      // The draft marker protects the files until the confirmed marker takes over.
      if !value.media.isEmpty {
        try Data().write(to: data.dir.appendingPathComponent(FeedbackConversationRecord.pendingMarker), options: .atomic)
      }
      try await save(current)
      if !value.media.isEmpty, !writeFeedbackConfirmedMarker(in: data.dir) { throw FeedbackHubError.storage }
      try model.draftStore.clear(id: data.id)
      // Retain the composer identity while prepare creates the next draft.
    } catch is CancellationError { busy = false; reset = UUID(); return }
    catch { self.error = "Could not save your message. Please try again." }
    busy = false; reset = UUID()
    if record?.pending != nil { await resume() }
  }
  private func resume() async {
    guard !busy, var current = record, var pending = current.pending else { return }
    busy = true; error = nil
    defer { busy = false; reset = UUID() }
    do {
      try check()
      let dir = model.draftStore.outboxRoot.appendingPathComponent(pending.id)
      // Recover a crash after the pending record was written but before the draft was cleared.
      if (try? model.draftStore.load())?.id == pending.id {
        if pending.hasMedia, !writeFeedbackConfirmedMarker(in: dir) { throw FeedbackHubError.storage }
        try model.draftStore.clear(id: pending.id)
      }
      // Keep a separate editable draft while the accepted local message is delivered.
      omitScreenshot = true
      if draft == nil || draft?.id == pending.id { await prepare() }
      if draft?.id == pending.id { draft = nil } // Preparation failed; retain the retry controls.
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
        current.pending = pending
        try await save(current)
      }
      // Bounded polling. A pending analysis remains retryable on the same message id.
      for attempt in 0..<4 {
        let snapshot = try await model.client.conversationTurn(current)
        current.snapshot = snapshot
        if !snapshot.pending {
          current.pending = nil
          try await save(current)
          if !pending.hasMedia { try? FileManager.default.removeItem(at: dir) }
          if draft == nil { await prepare() }
          return
        }
        try await save(current)
        if attempt < 3 { try await Task.sleep(for: .seconds(10)) }
      }
      error = "Your message is saved. The reply is not ready. Try again shortly."
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
    guard !busy, let pending = record?.pending else { return }
    do {
      try check()
      let dir = model.draftStore.outboxRoot.appendingPathComponent(pending.id)
      guard UUID(uuidString: pending.id) != nil, model.draftStore.ownsDirectory(dir) else { throw FeedbackHubError.storage }
      if let binding = try FeedbackCaptureBinding.read(in: dir) {
        guard binding.scope == model.client.storage.scope, binding.generation == model.identityGeneration else { throw FeedbackHubError.identityChanged }
      }
      if (try? model.draftStore.load())?.id == pending.id { try model.draftStore.clear(id: pending.id) }
      try await save(.init(generation: model.identityGeneration, id: UUID().uuidString.lowercased()))
      try? FileManager.default.removeItem(at: dir)
      draft = nil; omitScreenshot = true; error = nil
      await prepare()
    } catch is CancellationError { return }
    catch { self.error = "Could not start a new conversation. Please try again." }
  }
}
#endif
