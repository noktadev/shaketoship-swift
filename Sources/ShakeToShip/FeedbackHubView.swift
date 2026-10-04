import SwiftUI

#if canImport(UIKit)
  import SwiftUI

  /// Optional composition. The host owns all navigation and presentation chrome.
  struct FeedbackHubView: View {
    @Bindable var model: FeedbackHubModel
    @State private var report: FeedbackReportPresentation?
    @State private var suggest = false
    @State private var email = false
    var body: some View {
      List {
        Section {
          Button { report = FeedbackReportPresentation(screenshot: FeedbackReportScreenshot.captureForReport(model: model)) } label: {
            FeedbackEntryLabel(title: "Report a bug", systemImage: "ladybug")
          }
          if model.config.hub.contains(.ideas) {
            Button { suggest = true } label: {
              FeedbackEntryLabel(title: "Suggest an idea", systemImage: "lightbulb")
            }
            FeedbackRouteLink(route: .ideas) { Label("Ideas", systemImage: "arrow.up.square") }
          }
          if model.config.hub.contains(.inbox) {
            FeedbackRouteLink(route: .inbox) { Label("Inbox", systemImage: "tray") }
          }
        } header: {
          Text("Any feedback to share?").feedbackFont(.headline).textCase(nil)
            .feedbackPrimaryText()
        }.feedbackRow()
        if !model.config.hub.contains(.inbox) {
          Section {
            Button { email = true } label: {
            FeedbackEntryLabel(title: "Email updates", systemImage: "envelope")
          }.buttonStyle(.plain)
          }.feedbackRow()
        }
        if model.showEmailOffer { Section { FeedbackEmailOfferCard(model: model) }.feedbackRow() }
        FeedbackHubErrorSection(model: model)
      }
      .feedbackListStyle()
      .sheet(item: $report) { report in
        FeedbackHubReport(model: model, screenshot: report.screenshot).presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $suggest) { FeedbackSuggestView(model: model) }
      .sheet(isPresented: $email) { FeedbackEmailSheet(model: model) }
    }
  }

  struct FeedbackIdeasView: View {
    @Bindable var model: FeedbackHubModel
    @State private var suggest = false
    @Environment(\.shakeToShipTheme) private var theme
    var body: some View {
      List {
        FeedbackHubErrorSection(model: model)
        if model.showEmailOffer { Section { FeedbackEmailOfferCard(model: model) }.feedbackRow() }
        if let prompt = model.prompt, model.config.hub.contains(.prompts) {
          Section { FeedbackPromptCard(model: model, prompt: prompt) }.feedbackRow()
        }
        Section {
          Picker("Show ideas", selection: $model.filter) {
            Text("Top").tag("top")
            Text("New").tag("new")
            Text("Planned").tag("planned")
            Text("Shipped").tag("shipped")
            Text("Mine").tag("mine")
          }.pickerStyle(.menu).feedbackPrimaryText()
        }.feedbackRow()
        if model.loading && model.ideas.isEmpty {
          ProgressView("Loading ideas…").feedbackPrimaryText().frame(maxWidth: .infinity)
            .feedbackRow()
        } else if model.ideas.isEmpty {
          ContentUnavailableView {
            Label(
              model.error == nil ? "Your ideas belong here" : "Ideas are unavailable",
              systemImage: "lightbulb"
            ).feedbackPrimaryText()
          } description: {
            Text(
              model.error == nil
                ? "Suggest a change or vote for an idea you want the team to build."
                : "Check your connection and try again."
            ).foregroundStyle(theme.secondaryText ?? .secondary)
          } actions: {
            if model.error != nil {
              Button("Try again") { Task { await model.refreshIdeas() } }
            } else {
              Button("Suggest an idea") { suggest = true }
            }
          }.listRowBackground(theme.surface ?? .clear).feedbackRow()
        } else {
          Section {
            ForEach(model.ideas) { idea in
              HStack(alignment: .top, spacing: 12) {
                FeedbackVoteButton(model: model, idea: idea)
                FeedbackRouteLink(route: .idea(id: idea.id)) {
                  FeedbackIdeaRow(idea: idea, showsVotes: false)
                }
              }.feedbackRow()
            }
            if model.cursor != nil {
              Button("More ideas") { Task { await model.refreshIdeas(more: true) } }.feedbackRow()
            }
          } header: {
            Text("Shape what comes next").foregroundStyle(theme.secondaryText ?? .secondary)
          }
        }
        if let url = model.config.supportURL {
          Section { Link("Contact the team", destination: url) }.feedbackRow()
        }
      }
      .feedbackListStyle()
      .task {
        if model.ideas.isEmpty { await model.refreshIdeas() }
        await model.refreshPrompt()
      }
      .refreshable { await model.refreshIdeas() }
      .onChange(of: model.filter) { _, _ in Task { await model.refreshIdeas() } }
      .sheet(isPresented: $suggest) {
        FeedbackSuggestView(model: model).presentationDetents([.medium, .large])
      }

    }
  }
  struct FeedbackIdeaRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let idea: FeedbackIdea
    var showsVotes = true
    @Environment(\.shakeToShipTheme) private var theme
    var body: some View {
      HStack(alignment: .top, spacing: 16) {
        if showsVotes {
          FeedbackVoteLabel(idea: idea)
          .accessibilityLabel("\(idea.voteCount) votes\(idea.votedByMe ? ", including yours" : "")")
        }
        VStack(alignment: .leading, spacing: 6) {
          Text(idea.title).feedbackFont(.headline).foregroundStyle(theme.primaryText ?? .primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1).truncationMode(.tail)
          FeedbackStatusChip(idea: idea)
          if let summary = idea.body ?? idea.replyExcerpt {
            Text(summary).feedbackFont(.subheadline).foregroundStyle(
              theme.secondaryText ?? .secondary
            )
            .lineLimit(1)
          }
        }
      }
    }
  }
  struct FeedbackIdeaDetail: View {
    @Bindable var model: FeedbackHubModel
    let id: String
    var showsModeration = false
    @State private var privateDetail = false
    @State private var moderation = false
    @Environment(\.shakeToShipTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    var body: some View {
      Group {
        if let current = model.selectedIdea, current.id == id {
          List {
            FeedbackHubErrorSection(model: model)
            Section {
              HStack(alignment: .top, spacing: 16) {
                FeedbackVoteButton(model: model, idea: current)
                VStack(alignment: .leading, spacing: 12) {
                  Text(current.title).foregroundStyle(theme.primaryText ?? .primary).feedbackFont(
                    .title2.weight(.bold)
                  ).textSelection(.enabled)
                  if let body = current.body {
                    Text(body).foregroundStyle(theme.primaryText ?? .primary).textSelection(.enabled)
                  }
                  FeedbackStatusChip(idea: current)
                }
              }
            }.feedbackRow()
            if let reply = current.pinnedReply {
              Section {
                Label(reply.text, systemImage: "bubble.left.and.text.bubble.right")
                  .feedbackPrimaryText().textSelection(
                    .enabled)
              } header: {
                Text("From the team").foregroundStyle(theme.secondaryText ?? .secondary)
              }.feedbackRow()
            }
            Section {
              Button("Tell us more", systemImage: "lock") { privateDetail = true }
              Text("Only the team can read your details and attached reports.").feedbackFont(
                .footnote
              )
              .foregroundStyle(theme.secondaryText ?? .secondary)
            }.feedbackRow()
            Section {
              Button("Report or block", systemImage: "flag") { moderation = true }
                .contextMenu {
                  Button("Report idea", systemImage: "flag", role: .destructive) {
                    moderation = true
                  }
                  Button(
                    "Block author", systemImage: "person.crop.circle.badge.xmark",
                    role: .destructive
                  ) {
                    moderation = true
                  }
                }
              if let url = model.config.supportURL { Link("Contact the team", destination: url) }
            }.feedbackRow()
          }
          .sheet(isPresented: $privateDetail) {
            FeedbackPrivateDetailView(model: model, idea: current)
              .presentationDetents([.medium, .large])
          }
          .confirmationDialog(
            "Report or block this idea?", isPresented: $moderation, titleVisibility: .visible
          ) {
            Button("Report idea", role: .destructive) { moderate(current, block: false) }
            Button("Block author", role: .destructive) { moderate(current, block: true) }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text(
              "Reporting hides this idea and sends it to the team. Blocking hides this author's public ideas."
            )
          }
          .feedbackListStyle()

        } else if model.detailLoading {
          ProgressView("Loading idea…").feedbackPrimaryText()
        } else {
          ContentUnavailableView {
            Label("Idea unavailable", systemImage: "lightbulb.slash").feedbackPrimaryText()
          } description: {
            Text("This idea is no longer available. Return to Ideas to see current suggestions.")
              .foregroundStyle(theme.secondaryText ?? .secondary)
          }
        }
      }
      .feedbackBackground()
      .task(id: id) {
        await model.detail(id)
        if showsModeration { moderation = true }
      }
      .onChange(of: model.visibilityRevision) { _, _ in
        privateDetail = false
        moderation = false
        dismiss()
      }
    }
    private func moderate(_ idea: FeedbackIdea, block: Bool) {
      Task { _ = await model.moderate(idea, block: block) }
    }
  }
  struct FeedbackSuggestView: View {
    @Environment(\.shakeToShipTheme) private var theme
    @Bindable var model: FeedbackHubModel
    @State var title = ""
    @State var detail = ""
    @State var similar: [FeedbackIdea] = []
    @State var checked = false
    @State private var dedupUnavailable = false
    @State private var busy = false
    @State private var publishing = false
    @State private var attachment = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
      FeedbackSheet(title: "Suggest an idea") {
        Form {
          FeedbackHubErrorSection(model: model)
          Section {
            TextField("A short, clear title", text: $title, axis: .vertical).lineLimit(3...8)
              .feedbackPrimaryText()
              .accessibilityLabel(
                "Idea title"
              ).disabled(publishing)
          }.feedbackRow()
          Section {
            LabeledContent("Feedback type", value: "Feature request").feedbackPrimaryText()
          }.feedbackRow()
          Section {
            TextField("What would this help you do?", text: $detail, axis: .vertical)
              .feedbackPrimaryText().lineLimit(
                3...8
              ).accessibilityLabel("Public idea description").disabled(publishing)
          } header: {
            Text("Description").foregroundStyle(theme.secondaryText ?? .secondary)
          } footer: {
            Text(
              "Your title and description are public. Keep personal information out of your idea."
            )
            .foregroundStyle(theme.secondaryText ?? .secondary)
          }.feedbackRow()
          if checked {
            Section {
              ForEach(similar) { idea in
                VStack(alignment: .leading) {
                  FeedbackIdeaRow(idea: idea)
                  Button("Vote instead") {
                    Task {
                      let expected = model.revision
                      model.error = nil
                      await model.vote(idea)
                      if model.active, expected == model.revision, model.error == nil { dismiss() }
                    }
                  }.disabled(model.voting.contains(idea.id) || idea.votedByMe)
                }.feedbackSurface()
              }
              Text(
                dedupUnavailable
                  ? "You can publish your idea now or check again later."
                  : "You can vote for an existing idea or publish your own."
              ).feedbackFont(.footnote).foregroundStyle(theme.secondaryText ?? .secondary)
            } header: {
              Text(
                dedupUnavailable
                  ? "Similar ideas are unavailable"
                  : similar.isEmpty ? "No similar ideas found" : "Is your idea already here?"
              )
              .foregroundStyle(theme.secondaryText ?? .secondary)
            }.feedbackRow()
          }
          if !model.sessions.isEmpty {
            Section {
              Picker("Existing report (private)", selection: $attachment) {
                Text("None").tag("")
                ForEach(model.sessions) { session in
                  Text(session.createdAt.formatted()).tag(session.id)
                }
              }.feedbackPrimaryText().disabled(publishing)
            }.feedbackRow()
          }
          Section {
            Button(checked ? "Publish idea" : "Check similar ideas") { Task { await submit() } }
              .disabled(
                busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || title.count > 120 || detail.count > 2000)
            if busy { ProgressView("Checking…").feedbackPrimaryText() }
          }.feedbackRow()
        }.feedbackListStyle()
      } action: {
        Button("Send") { Task { await submit() } }
          .disabled(
            busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || title.count > 120 || detail.count > 2000)
      }
      .interactiveDismissDisabled(!title.isEmpty || !detail.isEmpty)

      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .onChange(of: title) { _, _ in clearSimilarity() }
      .onChange(of: detail) { _, _ in clearSimilarity() }
      .onChange(of: model.visibilityRevision) { _, _ in
        similar = []
        checked = false
        dedupUnavailable = false
      }
      .task {
        let expected = model.revision
        await model.perform {
          let sessions = try await model.client.attachableReports()
          guard expected == model.revision, model.active else { return }
          model.sessions = sessions
        }
      }
    }
    private func clearSimilarity() {
      checked = false
      similar = []
      dedupUnavailable = false
    }
    private func submit() async {
      let submittedTitle = title
      let submittedDetail = detail
      let submittedAttachment = attachment
      let shouldPublish = checked
      busy = true
      publishing = shouldPublish
      defer {
        busy = false
        publishing = false
      }
      let expected = model.revision
      let visibility = model.visibilityRevision
      await model.perform {
        var fields: [String: FeedbackHubValue] = [
          "title": .string(submittedTitle), "body": .string(submittedDetail),
        ]
        if shouldPublish {
          if !submittedAttachment.isEmpty {
            fields["attachmentSessionId"] = .string(submittedAttachment)
          }
          _ = try await model.client.decode(
            FeedbackIdea.self, path: "ideas", method: "POST", fields: fields)
          guard expected == model.revision else { return }
          dismiss()
          model.offerEmail()
          await model.refreshIdeas()
        } else {
          do {
            let response = try await model.client.decode(
              FeedbackSimilarIdeas.self, path: "ideas", method: "POST", fields: fields,
              query: [URLQueryItem(name: "dryRun", value: "1")])
            model.applyVisibleResponse(revision: expected, visibility: visibility) {
              guard title == submittedTitle, detail == submittedDetail else { return }
              similar = response.similar
              dedupUnavailable = false
              checked = true
            }
          } catch FeedbackHubError.http(503, _, _) {
            model.applyVisibleResponse(revision: expected, visibility: visibility) {
              guard title == submittedTitle, detail == submittedDetail else { return }
              similar = []
              dedupUnavailable = true
              checked = true
            }
          }
        }
      }
    }
  }
  struct FeedbackPrivateDetailView: View {
    @Bindable var model: FeedbackHubModel
    let idea: FeedbackIdea
    var body: some View {
      FeedbackHubReport(model: model, purpose: .idea(idea.id))
    }
  }

  /// Existing reports retain their own purpose. This explicit action creates only the authorized reference.
  struct FeedbackExistingReportDetail: View {
    @Environment(\.shakeToShipTheme) private var theme
    @Bindable var model: FeedbackHubModel
    let ideaID: String
    @State private var attachment = ""
    @State private var busy = false
    @State private var sent = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
      FeedbackSheet(title: "Existing report") {
        Form {
          FeedbackHubErrorSection(model: model)
          if sent {
            confirmation
          } else {
            Section {
              ForEach(model.sessions) { session in
                Button {
                  attachment = session.id
                } label: {
                  HStack {
                    Text(session.createdAt.formatted())
                    Spacer()
                    if attachment == session.id { Image(systemName: "checkmark") }
                  }
                }.accessibilityIdentifier("feedback-existing-report-" + session.id)
              }
            } footer: {
              Text(
                "Choose a report you already sent to the team. Only your reports can be attached."
              ).foregroundStyle(theme.secondaryText ?? .secondary)
            }.feedbackRow()
            Button("Attach privately") { Task { await attach() } }
              .disabled(attachment.isEmpty || busy).feedbackRow()
            if busy { ProgressView() }
          }
        }.feedbackListStyle()
      } action: {
        if sent {
          Button("Done") { dismiss() }
        } else {
          Button("Send") { Task { await attach() } }.disabled(attachment.isEmpty || busy)
        }
      }
      .interactiveDismissDisabled(!sent && !attachment.isEmpty)
    }
    var confirmation: some View {
      Label("Report attached privately", systemImage: "checkmark.circle")
        .feedbackPrimaryText().feedbackRow()
    }
    private func attach() async {
      busy = true
      defer { busy = false }
      let expected = model.revision
      await model.perform {
        try await model.client.attachExistingReport(attachment, to: ideaID)
        guard expected == model.revision, model.active else { return }
        sent = true
      }
    }
  }
  struct FeedbackInboxView: View {
    @Environment(\.shakeToShipTheme) private var theme
    @Bindable var model: FeedbackHubModel
    @State private var email = false
    @State private var report: FeedbackReportPresentation?
    var body: some View {
      List {
        Section {
          Button { report = FeedbackReportPresentation(screenshot: FeedbackReportScreenshot.captureForReport(model: model)) } label: {
            FeedbackEntryLabel(title: "Submit new ticket", systemImage: "plus")
          }.buttonStyle(.plain)
        }.feedbackRow()
        FeedbackHubErrorSection(model: model)
        if model.inboxLoading && model.inbox.isEmpty {
          ProgressView("Loading your inbox…").feedbackPrimaryText().feedbackRow()
        } else if let error = model.inboxError, model.inbox.isEmpty {
          ContentUnavailableView {
            Label("Inbox is unavailable", systemImage: "tray").feedbackPrimaryText()
          } description: {
            Text(error).foregroundStyle(theme.secondaryText ?? .secondary)
          } actions: {
            Button("Try again") { Task { await model.refreshInbox() } }
          }.feedbackRow()
        } else if model.inbox.isEmpty {
          ContentUnavailableView {
            Label("You're all caught up", systemImage: "tray").feedbackPrimaryText()
          } description: {
            Text("Replies and progress on your feedback appear here.")
              .foregroundStyle(theme.secondaryText ?? .secondary)
          }
          .listRowBackground(theme.surface ?? .clear).feedbackRow()
        } else {
          Section {
            ForEach(model.inbox) { message in
              Group {
                if let id = message.ideaId, model.config.hub.contains(.ideas) {
                  FeedbackRouteLink(route: .idea(id: id)) { ticket(message) }
                    .accessibilityIdentifier("View idea")
                } else {
                  ticket(message)
                }
              }
              .accessibilityValue("Unread")
              .accessibilityAction(named: "Mark as read") { Task { await model.acknowledge(message) } }
              .contextMenu {
                Button("Mark as read") { Task { await model.acknowledge(message) } }
              }.feedbackRow()
            }
          } header: {
            Text("My tickets").foregroundStyle(theme.secondaryText ?? .secondary)
          }
        }
        FeedbackOwnedReportSection(model: model, refreshToken: report == nil)
        Section {
          Button { email = true } label: {
            FeedbackEntryLabel(title: "Email updates", systemImage: "envelope")
          }.buttonStyle(.plain)
        }.feedbackRow()
      }.feedbackListStyle()
        .sheet(isPresented: $email) { FeedbackEmailSheet(model: model) }
        .sheet(item: $report) { report in FeedbackHubReport(model: model, screenshot: report.screenshot) }
        .refreshable { await model.refreshInbox() }.task {
          await model.refreshInbox()
        }
    }
    private func ticket(_ message: FeedbackInboxMessage) -> some View {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: message.ideaId == nil ? "doc.text" : "bubble.left.and.text.bubble.right")
          .foregroundStyle(theme.secondaryText ?? .secondary)
          .frame(width: 40, height: 40)
          .background((theme.secondaryText ?? .secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(message.payload.title ?? "Feedback update").feedbackFont(.headline)
              .foregroundStyle(theme.primaryText ?? .primary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Circle().fill(.tint).frame(width: 7, height: 7)
              .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
              .accessibilityHidden(true)
          }
          HStack {
            Text(message.kind.replacingOccurrences(of: "_", with: " ").capitalized)
              .lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
              .background(.tint.opacity(0.08), in: Capsule())
            Spacer(minLength: 8)
            if let date = try? Date(message.createdAt, strategy: .iso8601) {
              Text(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
            }
          }.feedbackFont(.caption, inherit: false).foregroundStyle(theme.secondaryText ?? .secondary)
            .lineLimit(1)
          if let text = message.payload.text {
            Text(text).feedbackFont(.subheadline).foregroundStyle(theme.secondaryText ?? .secondary)
              .lineLimit(1).truncationMode(.tail)
          }
        }
      }
    }
  }
  struct FeedbackInboxIdea: View {
    @Bindable var model: FeedbackHubModel
    let id: String
    var body: some View {
      FeedbackIdeaDetail(model: model, id: id)
    }
  }
  struct FeedbackEmailView: View {
    @Environment(\.shakeToShipTheme) private var theme
    @Bindable var model: FeedbackHubModel
    @State private var address = ""
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
      FeedbackSheet(title: "Email updates") {
        Form {
          FeedbackHubErrorSection(model: model)
          Section {
            Text(
              "Optional email updates let you know when the team responds. You can unsubscribe at any time."
            )
            .feedbackPrimaryText()
            if let status = model.emailStatus {
              Text(status.description).feedbackPrimaryText()
              if status.delivery != "disabled" {
                TextField("Email address", text: $address).feedbackPrimaryText()
                  .keyboardType(.emailAddress).textContentType(.emailAddress)
                  .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(status.canUnsubscribe ? "Update email" : "Request email updates") {
                  Task {
                    busy = true
                    model.error = nil
                    await model.enroll(address)
                    if model.error == nil { address = "" }
                    busy = false
                  }
                }.disabled(address.isEmpty || busy)
              }
              if status.canUnsubscribe {
                Button("Unsubscribe", role: .destructive) {
                  Task {
                    busy = true
                    await model.unsubscribe()
                    busy = false
                  }
                }.disabled(busy)
              }
            } else {
              ProgressView("Checking email settings…").feedbackPrimaryText()
              Button("Try again") { Task { await model.refreshEmail() } }
            }
          } footer: {
            Text("Your email is private. It does not appear on your ideas.")
              .foregroundStyle(theme.secondaryText ?? .secondary)
          }.feedbackRow()
          if let notice = model.emailNotice {
            Section { Text(notice).feedbackPrimaryText() }.feedbackRow()
          }
        }.feedbackListStyle()
      } action: {
        Button("Done") { dismiss() }
      }
      .interactiveDismissDisabled(!address.isEmpty)
      .task { await model.refreshEmail() }
    }
  }
  struct FeedbackHubErrorSection: View {
    @Bindable var model: FeedbackHubModel
    var body: some View {
      if let error = model.error {
        Section {
          Label(error, systemImage: "exclamationmark.circle").feedbackPrimaryText()
          Button("Dismiss message") { model.error = nil }
        }.feedbackRow()
      }
    }
  }
#endif

struct FeedbackPromptCard: View {
  @Bindable var model: FeedbackHubModel
  let prompt: FeedbackPrompt
  var body: some View { FeedbackPromptAnswerCard(model: model, prompt: prompt) }
}

struct FeedbackPromptAnswerCard: View {
  @Bindable var model: FeedbackHubModel
  let prompt: FeedbackPrompt
  var onClose: () -> Void = {}
  @State private var answer = ""
  @State private var selection: Int?
  @State private var busy = false
  var body: some View {
    FeedbackCard(symbol: "bubble.left", title: prompt.question, message: "Your response is private.") {
      if prompt.kind == "text" {
        TextField("Your private response", text: $answer, axis: .vertical)
          .lineLimit(3...8).textFieldStyle(.roundedBorder).foregroundStyle(.primary)
          .accessibilityLabel("Your private response")
      } else {
        VStack(spacing: 0) {
          ForEach(prompt.kind == "rating" ? Array(1...5) : [1, 0], id: \.self) { value in
            if value != 1 { Divider() }
            Button { selection = value } label: {
              HStack {
                Text(prompt.kind == "rating" ? "\(value) out of 5" : value == 1 ? "Yes" : "No")
                  .feedbackPrimaryText()
                Spacer()
                Image(systemName: selection == value ? "checkmark.circle.fill" : "circle")
              }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
              .accessibilityValue(selection == value ? "Selected" : "Not selected")
          }
        }
      }
      if let error = model.error { Text(error).feedbackPrimaryText().font(.footnote) }
      FeedbackCardAction(title: "Send") { respond(dismiss: false) }
        .disabled(response.map { !prompt.accepts($0) } != false)
      Button("Not now") { respond(dismiss: true) }.buttonStyle(.plain).frame(minHeight: 44)
        .accessibilityIdentifier("Dismiss question")
    }.disabled(busy)
  }
  private var response: FeedbackHubValue? {
    if prompt.kind == "text" { return .string(answer) }
    guard let selection else { return nil }
    return prompt.kind == "rating" ? .integer(selection) : .bool(selection == 1)
  }
  private func respond(dismiss: Bool) {
    guard !busy else { return }
    let value = response
    busy = true
    model.error = nil
    Task {
      await model.respond(prompt, value: value, dismiss: dismiss)
      busy = false
      if model.error == nil { onClose() }
    }
  }
}
