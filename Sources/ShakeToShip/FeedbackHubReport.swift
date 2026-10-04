#if canImport(UIKit)
  import SwiftUI

  /// The hub reuses the existing composer, evidence persistence, confirmation, and uploader.
  struct FeedbackHubReport: View {
    @Bindable var model: FeedbackHubModel
    @Environment(\.shakeToShipTheme) private var theme
    var purpose: FeedbackCapturePurpose = .report
    private var isIdea: Bool { purpose.kind == "idea" }
    @Environment(\.dismiss) private var dismiss
    @State private var existing = false
    @State private var data: FeedbackComposerData?
    @State private var result: String?
    @State private var sending = false
    @State private var preparing = true
    @State private var actionReset = UUID()
    @State private var resultIcon = "checkmark.bubble"
    var body: some View {
      FeedbackSheet(title: isIdea ? "Tell us more" : "Send a report") {
        if let data {
          FeedbackComposer(
            data: data, onSend: { value in Task { await send(data, value) } },
            onDiscard: { discard(data) },
            onOptOut: isIdea ? nil : model.config.onOptOut.map { callback in { callback() } },
            actionReset: actionReset, inheritsHostStyle: true,
            formHeader: AnyView(reportHeader),
            formFooter: AnyView(existingReportRow)
          )
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
      .scrollDismissesKeyboard(.interactively)
      .feedbackBackground()
      .task { if data == nil && result == nil { await prepare() } }
    }
    private var reportHeader: some View {
      Group {
        FeedbackHubErrorSection(model: model)
        Section {
          if isIdea, let idea = model.selectedIdea, idea.id == purpose.ideaId {
            Text(idea.title).feedbackFont(.headline).feedbackPrimaryText()
          }
          LabeledContent("Feedback type", value: isIdea ? "Private response" : "Bug report")
            .feedbackPrimaryText()
        }.feedbackRow()
      }
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
        data = FeedbackComposerData(
          id: id, dir: dir, events: [],
          contextNote: isIdea
            ? "Only the team can read this response. It stays out of the public idea and GitHub issues."
            : nil,
          capabilities: isIdea ? [.text] : model.config.capabilities,
          notePrompt: isIdea ? "Tell us more…" : "What happened?",
          sendLabel: isIdea ? "Send privately" : "Send",
          showsTrail: false,
          maxAttachmentDuration: model.config.maxAttachmentDuration)
        result = nil
      }
    }
    private func discard(_ draft: FeedbackComposerData) {
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
        guard !isIdea || value.media.isEmpty else { throw FeedbackHubError.invalidResponse }
        guard persistComposedReport(value, in: draft.dir) else { throw FeedbackHubError.storage }
        let session = FeedbackSession(
          session_id: draft.id, app: model.config.app,
          build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
          started_at: ISO8601DateFormatter().string(from: Date()), user_ref: nil, events: [])
        try JSONEncoder().encode(session).write(
          to: draft.dir.appendingPathComponent("events.json"), options: .atomic)
        guard writeFeedbackConfirmedMarker(in: draft.dir) else { throw FeedbackHubError.storage }
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
