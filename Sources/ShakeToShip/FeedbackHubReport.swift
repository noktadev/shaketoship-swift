#if canImport(UIKit)
  import SwiftUI

  /// The hub reuses the existing composer, evidence persistence, confirmation, and uploader.
  struct FeedbackHubReport: View {
    @Bindable var model: FeedbackHubModel
    @Environment(\.shakeToShipTheme) private var theme
    var purpose: FeedbackCapturePurpose = .report
    var screenshot: Data? = nil
    private var isIdea: Bool { purpose.kind == "idea" }
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCapture = false
    @State private var existing = false
    @State private var data: FeedbackComposerData?
    @State private var result: String?
    @State private var sending = false
    @State private var preparing = true
    @State private var actionReset = UUID()
    @State private var resultIcon = "checkmark.bubble"
    var body: some View {
      FeedbackSheet(title: isIdea ? "Tell us more" : "Report a bug") {
        if let data {
          FeedbackComposer(
            data: data, onSend: { value in Task { await send(data, value) } },
            onDiscard: { discard(data) },
            onOptOut: isIdea ? nil : model.config.onOptOut.map { callback in { callback() } },
            actionReset: actionReset, inheritsHostStyle: true,
            formHeader: AnyView(reportHeader),
            formFooter: AnyView(reportFooter),
            onDraftChange: isIdea ? nil : { try saveDraft($0, id: data.id) },
            onRecord: isIdea ? nil : { value in
              guard !pendingCapture else { throw FeedbackHubError.storage }
              try saveDraft(value, id: data.id)
              FeedbackManualTrigger.reportRecording = FeedbackReportRecording(store: model.draftStore, draftID: data.id)
              FeedbackSDKPresentationMarker.requestWalkthrough()
            }
          )
          .id(data.initialMedia.map(\.id))
          .disabled(sending)
        } else {
          Form {
            FeedbackHubErrorSection(model: model)
            if let result {
              ContentUnavailableView {
                Label(result, systemImage: resultIcon).feedbackPrimaryText()
              } description: {
                Text("Thank you for helping the team improve this app.").foregroundStyle(
                  theme.secondaryText ?? .secondary)
              } actions: {
                Button(isIdea ? "Add more details" : "Write another report") {
                  Task { await prepare() }
                }
              }
            } else if preparing {
              ProgressView(isIdea ? "Preparing your response…" : "Preparing your report…")
                .feedbackPrimaryText()
            } else {
              Button("Try again") { Task { await prepare() } }
            }
            if result != nil, model.showEmailOffer {
              Section { FeedbackEmailOfferCard(model: model) }.feedbackRow()
            }
            existingReportRow
          }.feedbackListStyle()
        }
      } action: {
        if data == nil { Button("Done") { dismiss() } }
      }
      .sheet(isPresented: $existing) {
        if let ideaID = purpose.ideaId {
          FeedbackExistingReportDetail(model: model, ideaID: ideaID)
        }
      }
      .background(FeedbackSDKPresentationMarker())
      .scrollDismissesKeyboard(.interactively)
      .feedbackBackground()
      .task { if data == nil && result == nil { await prepare() } }
    }
    private var reportHeader: some View {
      Group {
        FeedbackHubErrorSection(model: model)
        if pendingCapture {
          Section {
            Text("Your recording could not be added. Your report is saved.")
            Button("Try adding recording again") { Task { await prepare() } }
            Button("Discard recording", role: .destructive) { discardPendingCapture() }
          }.feedbackRow()
        }
        if isIdea { Section {
          if let idea = model.selectedIdea, idea.id == purpose.ideaId {
            Text(idea.title).feedbackFont(.headline).feedbackPrimaryText()
          }
          LabeledContent("Feedback type", value: isIdea ? "Private response" : "Bug report")
            .feedbackPrimaryText()
        }.feedbackRow() }
      }
    }
    @ViewBuilder private var reportFooter: some View {
      existingReportRow
      #if targetEnvironment(simulator)
      if !isIdea { Section {} footer: { FeedbackRecordingDeviceHint() } }
      #endif
    }
    @ViewBuilder private var existingReportRow: some View {
      if isIdea, !model.sessions.isEmpty {
        Section {
          Button("Attach an existing report") { existing = true }
        }.feedbackRow()
      }
    }
    private func prepare() async {
      preparing = true
      defer { preparing = false }
      model.error = nil
      let expected = model.revision
      await model.perform {
        if !isIdea, var saved = try model.draftStore.load() {
          if let captureID = saved.captureID {
            let capture = saved.directory.deletingLastPathComponent().appendingPathComponent(captureID)
            if let sessionData = try? Data(contentsOf: capture.appendingPathComponent("events.json")),
              let session = try? JSONDecoder().decode(FeedbackSession.self, from: sessionData) {
              do {
                saved = try await FeedbackReportRecording(store: model.draftStore, draftID: saved.id)
                  .completeCapture(in: capture, session: session)
              } catch {
                pendingCapture = true
                model.error = "Could not add the recording. Try again or discard the recording."
              }
            } else {
              // No finalized frames after a refused or interrupted start.
              saved.captureID = nil
              try model.draftStore.save(saved)
              try? FileManager.default.removeItem(at: capture)
            }
          }
          guard expected == model.revision, model.active else { return }
          pendingCapture = saved.captureID != nil
          data = composerData(saved)
          result = nil
          return
        }
        let id = UUID().uuidString
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("feedback-outbox/" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
          try await model.client.bindCapture(in: dir, purpose: purpose)
          guard expected == model.revision, model.active else {
            try? FileManager.default.removeItem(at: dir)
            return
          }
        } catch {
          try? FileManager.default.removeItem(at: dir)
          throw error
        }
        let initialMedia = try FeedbackReportScreenshot.stage(isIdea ? nil : screenshot, in: dir)
        if !isIdea {
          let saved = FeedbackReportDraft(id: id, directory: dir, generation: model.draftStore.generation, media: initialMedia)
          try model.draftStore.save(saved)
          data = composerData(saved)
          result = nil
          return
        }
        data = FeedbackComposerData(
          id: id, dir: dir, events: [],
          contextNote: isIdea
            ? "Only the team can read this response. It stays out of the public idea and GitHub issues."
            : nil,
          capabilities: isIdea ? [.text] : model.config.capabilities,
          notePrompt: isIdea ? "Tell us more…" : "What happened?",
          sendLabel: isIdea ? "Send privately" : "Send",
          showsTrail: false,
          initialMedia: initialMedia,
          titlePrompt: isIdea ? nil : "Briefly describe the problem",
          maxAttachmentDuration: model.config.maxAttachmentDuration)
        result = nil
      }
    }
    private func discardPendingCapture() {
      do {
        guard var saved = try model.draftStore.load(), let capture = saved.captureID else { return }
        saved.captureID = nil
        try model.draftStore.save(saved)
        try? FileManager.default.removeItem(at: saved.directory.deletingLastPathComponent().appendingPathComponent(capture))
        pendingCapture = false
        model.error = nil
      } catch { model.error = error.localizedDescription }
    }
    private func composerData(_ draft: FeedbackReportDraft) -> FeedbackComposerData {
      FeedbackComposerData(id: draft.id, dir: draft.directory, events: draft.events,
        capabilities: model.config.capabilities, showsTrail: false, initialMedia: draft.media,
        titlePrompt: "Briefly describe the problem", initialTitle: draft.title, initialNote: draft.note,
        maxAttachmentDuration: model.config.maxAttachmentDuration)
    }
    private func saveDraft(_ value: FeedbackComposerDraftValue, id: String) throws {
      guard model.active, var saved = try model.draftStore.load(), saved.id == id else {
        throw FeedbackHubError.identityChanged
      }
      saved.update(value)
      try model.draftStore.save(saved)
    }
    private func discard(_ draft: FeedbackComposerData) {
      do {
        if !isIdea {
          let saved = try model.draftStore.load()
          try model.draftStore.clear(id: draft.id)
          if let capture = saved?.captureID {
            try? FileManager.default.removeItem(at: draft.dir.deletingLastPathComponent().appendingPathComponent(capture))
          }
        }
      } catch { model.error = error.localizedDescription; actionReset = UUID(); return }
      try? FileManager.default.removeItem(at: draft.dir)
      data = nil
      resultIcon = "trash"
      result = isIdea ? "Response discarded" : "Report discarded"
    }
    private func send(_ draft: FeedbackComposerData, _ value: FeedbackComposerResult) async {
      sending = true
      defer { sending = false }
      let expected = model.revision
      model.error = nil
      await model.perform {
        guard !pendingCapture else { throw FeedbackHubError.storage }
        guard !isIdea || value.media.isEmpty else { throw FeedbackHubError.invalidResponse }
        if !isIdea, !value.media.contains(where: \.isRecorded) {
          let removedRecording = draft.dir.appendingPathComponent("recording.mov")
          if FileManager.default.fileExists(atPath: removedRecording.path) {
            try FileManager.default.removeItem(at: removedRecording)
          }
        }
        guard persistComposedReport(value, in: draft.dir) else { throw FeedbackHubError.storage }
        let session = FeedbackSession(
          session_id: draft.id, app: model.config.app,
          build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
          started_at: ISO8601DateFormatter().string(from: Date()), user_ref: nil,
          events: value.media.contains(where: \.isRecorded) ? draft.events : [])
        try JSONEncoder().encode(session).write(
          to: draft.dir.appendingPathComponent("events.json"), options: .atomic)
        guard writeFeedbackConfirmedMarker(in: draft.dir) else { throw FeedbackHubError.storage }
        if !isIdea { try model.draftStore.clear(id: draft.id) }
        let uploader = FeedbackUploader(
          config: model.config, transport: FeedbackBackgroundUploads.transport,
          fileManager: .default, outboxRoot: draft.dir.deletingLastPathComponent(),
          hubClient: model.client)
        let upload = await uploader.upload(sessionId: draft.id)
        guard expected == model.revision else { return }
        if isIdea {
          switch upload {
          case .uploaded:
            resultIcon = "checkmark.bubble"
            result = "Private response sent"
          case .retryableFailure:
            resultIcon = "clock"
            result = "Private response saved for retry"
          case .recordingTooLarge, .rejected:
            resultIcon = "exclamationmark.bubble"
            result = "Private response could not be sent"
          }
        } else {
          result = FeedbackHUDState.status(for: upload, confirmed: true).text
        }
        data = nil
        if !isIdea, upload == .uploaded || upload == .retryableFailure {
          model.offerEmail(after: expected)
        }
      }
      // A pre-upload storage failure keeps the same view state and draft binding.
      if data != nil, model.active, expected == model.revision { actionReset = UUID() }
    }
  }
#endif
