#if canImport(UIKit)
  import SwiftUI
  import UIKit
  @testable import ShakeToShip

  struct HubSnapshotTransport: FeedbackTransport {
    let email: String
    let inbox: String
    var unavailable = false
    var servesPrompt = false
    var emptyIdeas = false
    var ideasError = false
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      let body: String
      switch request.url!.path {
      case "/identity":
        body =
          "{\"reporterId\":\"fixture\",\"reporterToken\":\"rt1.eyJleHAiOjQwMDAwMDAwMDB9.signature\"}"
      case "/prompts/next": body = servesPrompt ? HubSnapshotFixtures.promptJSON : ""
      case "/reporter/email": body = email
      case "/v2/inbox": body = inbox
      case "/ideas/sample": body = HubSnapshotFixtures.ideaJSON
      case "/ideas":
        body = emptyIdeas ? #"{"ideas":[],"nextCursor":null}"# : HubSnapshotFixtures.ideasJSON
      default: body = "{}"
      }
      return (
        Data(body.utf8),
        HTTPURLResponse(
          url: request.url!,
          statusCode: ideasError && request.url!.path == "/ideas"
            ? 503
            : request.url!.path == "/prompts/next" && !servesPrompt
              ? 204 : unavailable && request.url!.path == "/ideas/sample" ? 404 : 200,
          httpVersion: nil, headerFields: nil)!
      )
    }
    func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
      try await perform(request)
    }
  }
  enum HubSnapshotFixtures {
    static let promptJSON =
      #"{"id":"c0000000-0000-4000-8000-000000000001","kind":"yes_no","question":"Would saved drafts help you?","impressionId":"d0000000-0000-4000-8000-000000000001"}"#
    static let ideaJSON =
      #"{"id":"sample","title":"Save a draft before leaving","body":"Keep unfinished work so I can return to it later, even after closing the app.","status":"planned","voteCount":42,"votedByMe":true,"replyExcerpt":"We're exploring this for the next release.","createdAt":"2026-09-23T00:00:00Z","pinnedReply":{"text":"We're exploring this for the next release. Tell us where a saved draft would help you most.","updatedAt":"2026-09-23T00:00:00Z"},"myDetailCount":1}"#
    static var ideasJSON: String {
      "{\"ideas\":[" + ideaJSON
        + #",{"id":"second","title":"A quieter reading mode","status":"open","voteCount":18,"votedByMe":false},{"id":"third","title":"Find recent work faster","status":"shipped","voteCount":27,"votedByMe":false,"replyExcerpt":"Available in the latest update."}],"nextCursor":null}"#
    }
    static let inboxJSON =
      #"{"messages":[{"id":"message","kind":"planned","ideaId":"sample","createdAt":"2026-09-23T00:00:00Z","payload":{"title":"Save a draft before leaving","text":"The team has planned this idea. Thank you for helping shape what comes next."}}]}"#
    static let fixedInboxJSON =
      #"{"messages":[{"id":"c0000000-0000-4000-8000-000000000001","kind":"fixed","ideaId":null,"createdAt":"2026-09-23T00:00:00Z","payload":{"title":"Your report is fixed"}}]}"#
    static func email(_ consent: String, replacement: Bool = false, disabled: Bool = false)
      -> String
    {
      "{\"delivery\":\"\(disabled ? "disabled" : "enabled")\",\"consent\":\"\(consent)\",\"pendingReplacement\":\(replacement),\"revision\":3}"
    }
  }

  extension HubSnapshotFixtures {
    @MainActor static func scene(_ requestedName: String) async throws -> (
      AnyView, FeedbackHubModel, URL
    ) {
      let lockin = requestedName.hasSuffix("-lockin")
      let name = lockin ? String(requestedName.dropLast(7)) : requestedName
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let config = ShakeToShipConfig(
        app: "com.example.hub", collectorURL: URL(string: "https://fixture.invalid")!,
        secret: "fixture",
        capabilities: [.text, .photoLibrary],
        hub: name == "hub-ideas-only" ? [.ideas] : [.ideas, .inbox, .prompts],
        supportURL: URL(string: "https://example.com/support"))
      let email = HubSnapshotFixtures.email(
        name == "email-offer" ? "none" : name == "email-pending" ? "pending" : "verified",
        replacement: name == "email-replacement", disabled: name == "email-disabled")
      let inbox =
        name == "inbox-empty"
        ? #"{"messages":[]}"#
        : name == "inbox-fixed" ? HubSnapshotFixtures.fixedInboxJSON : HubSnapshotFixtures.inboxJSON
      let client = try FeedbackHubClient(
        config: config,
        storage: FeedbackHubStorage(
          scope: name, root: root, readIdentity: { nil }, writeIdentity: { _ in }),
        transport: HubSnapshotTransport(
          email: email, inbox: inbox, unavailable: name == "idea-unavailable",
          servesPrompt: name == "prompt-card" || name == "prompt-banner"
            || name == "prompt-popover",
          emptyIdeas: name == "ideas-empty", ideasError: name == "ideas-error"
        ),
        now: { Date(timeIntervalSince1970: 1_790_121_600) })
      await client.setActive(true)
      let model = FeedbackHubModel(client: client, config: config)
      if name == "private-detail" || name == "existing-report" {
        let reporter = try await client.identity()
        let binding = FeedbackCaptureBinding(
          scope: name, generation: await client.generation, purpose: .report)
        try await client.saveSessionRecord(
          "fixture-report", captureId: "external-report", binding: binding, reporter: reporter)
        model.sessions = try await client.attachableReports()
      }

      let idea = try JSONDecoder().decode(
        FeedbackIdea.self, from: Data(HubSnapshotFixtures.ideaJSON.utf8))
      model.ideas = [
        idea,
        FeedbackIdea(
          id: "second", title: "A quieter reading mode", status: "open", voteCount: 18,
          votedByMe: false, replyExcerpt: nil),
        FeedbackIdea(
          id: "third", title: "Find recent work faster", status: "shipped", voteCount: 27,
          votedByMe: false, replyExcerpt: "Available in the latest update."),
      ]
      model.selectedIdea = idea
      model.emailStatus = try JSONDecoder().decode(FeedbackEmailStatus.self, from: Data(email.utf8))
      model.inbox = try JSONDecoder().decode(FeedbackInbox.self, from: Data(inbox.utf8)).messages
      let kind = name == "prompt-rating" ? "rating" : name == "prompt-text" ? "text" : "yes_no"
      let prompt = FeedbackPrompt(
        id: "prompt", kind: kind, question: "Would saved drafts help you?",
        impressionId: "impression")
      ShakeToShip.model = model
      let content: AnyView
      switch name {
      case "hub-sheet", "hub-ideas-only": content = AnyView(HarnessSheet { FeedbackHubSheet() })
      case "report":
        content = AnyView(HarnessSheet { FeedbackHubReport(model: model) })
      case "ideas", "ideas-dark":
        content = AnyView(ShakeToShipIdeasList())
      case "ideas-empty", "ideas-error":
        model.ideas = []
        if name == "ideas-error" { model.error = "Feedback could not connect. Try again." }
        content = AnyView(ShakeToShipIdeasList())
      case "idea-detail", "detail-large-type", "idea-unavailable":
        content = AnyView(ShakeToShipIdeaDetail(id: idea.id))
      case "suggest": content = AnyView(HarnessSheet { ShakeToShipSuggestSheet() })
      case "suggest-dedup":
        var suggestion = idea
        suggestion.votedByMe = false
        suggestion.voteCount = 41
        model.selectedIdea = suggestion
        model.ideas[0] = suggestion
        content = AnyView(
          HarnessSheet {
            FeedbackSuggestView(
              model: model, title: "Keep my unfinished work",
              detail: "Let me continue a draft after I close the app.", similar: [suggestion],
              checked: true)
          })
      case "private-detail":
        content = AnyView(HarnessSheet { FeedbackPrivateDetailView(model: model, idea: idea) })
      case "existing-report":
        content = AnyView(
          HarnessSheet { FeedbackExistingReportDetail(model: model, ideaID: idea.id) })
      case "moderation":
        content = AnyView(HarnessModeration(model: model))
      case "inbox", "inbox-empty", "inbox-fixed":
        content = AnyView(ShakeToShipInboxList())
      case "email-offer":
        content = AnyView(ScrollView { ShakeToShipEmailConsentCard() })
      case "email-pending", "email-verified", "email-replacement", "email-disabled":
        content = AnyView(HarnessSheet { ShakeToShipEmailConsentSheet() })
      case "prompt-card":
        content = AnyView(ShakeToShipIdeasList())
      case "prompt-banner":
        content = AnyView(ScrollView { ShakeToShipPromptCard() })
      case "prompt-popover":
        content = AnyView(HarnessPromptPopover())
      default:
        content = AnyView(
          ScrollView { FeedbackPromptCard(model: model, prompt: prompt) })
      }
      let host =
        lockin
        ? AnyView(LockInStyledHost { content.feedbackTheme() })
        : AnyView(SystemHost { content.feedbackTheme() })
      let view = host.environment(\.colorScheme, name == "ideas-dark" ? .dark : .light)
        .environment(
          \.dynamicTypeSize,
          ProcessInfo.processInfo.arguments.contains("--xxxLarge")
            ? .xxxLarge
            : name == "detail-large-type" ? .accessibility2 : .large)
      return (AnyView(view), model, root)
    }
  }

  /// The application owns the stack, navigation title, and destination placement.
  struct SystemHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
      NavigationStack {
        content().shakeToShipDestinations().navigationTitle("Settings")
      }
    }
  }

  /// Mock host tokens only. No LockInKit dependency enters this package.
  struct LockInStyledHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
      NavigationStack {
        VStack(alignment: .leading, spacing: 0) {
          VStack(alignment: .leading, spacing: 6) {
            Text("LOCK IN CHINESE").font(.caption.weight(.semibold)).tracking(2)
            Text("Make it yours.").font(.system(.largeTitle, design: .serif))
            Text("A place for your ideas.").foregroundStyle(.secondary)
          }.padding()
          content().shakeToShipDestinations()
        }
        .background(Self.theme(dark: colorScheme == .dark).background)
        .navigationTitle("Practice").navigationBarTitleDisplayMode(.inline)
      }
      .shakeToShipTheme(Self.theme(dark: colorScheme == .dark))
      .tint(Self.accent)
    }
    static var accent: Color { Color(red: 157 / 255, green: 42 / 255, blue: 43 / 255) }
    static func theme(dark: Bool) -> ShakeToShipTheme {
      ShakeToShipTheme(
        accent: dark ? Color(red: 216 / 255, green: 96 / 255, blue: 79 / 255) : accent,
        background: dark
          ? Color(red: 26 / 255, green: 23 / 255, blue: 18 / 255)
          : Color(red: 244 / 255, green: 241 / 255, blue: 234 / 255),
        surface: dark
          ? Color(red: 36 / 255, green: 32 / 255, blue: 25 / 255)
          : Color(red: 251 / 255, green: 249 / 255, blue: 243 / 255),
        primaryText: dark
          ? Color(red: 236 / 255, green: 230 / 255, blue: 216 / 255)
          : Color(red: 29 / 255, green: 29 / 255, blue: 27 / 255),
        secondaryText: dark
          ? Color(red: 184 / 255, green: 176 / 255, blue: 160 / 255)
          : Color(red: 74 / 255, green: 70 / 255, blue: 61 / 255),
        fontDesign: .serif, cornerRadius: 20, listStyle: .insetGrouped,
        statusColors: [
          "planned": dark ? Color(red: 216 / 255, green: 96 / 255, blue: 79 / 255) : accent,
          "shipped": dark
            ? Color(red: 166 / 255, green: 212 / 255, blue: 176 / 255)
            : Color(red: 74 / 255, green: 106 / 255, blue: 79 / 255),
        ])
    }
  }

  struct HarnessSheet<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var presented = false
    var body: some View {
      ShakeToShipIdeasList()
        .sheet(isPresented: $presented) {
          content().feedbackTheme().presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task { presented = true }
    }
  }
  struct HarnessModeration: View {
    let model: FeedbackHubModel
    var body: some View { FeedbackIdeaDetail(model: model, id: "sample", showsModeration: true) }
  }
  struct HarnessPromptPopover: View {
    @State private var presented = false
    var body: some View {
      ShakeToShipPromptPopover(isPresented: $presented) {
        Label("Question", systemImage: "bubble.left")
      }
      .task { presented = true }
    }
  }
#endif
