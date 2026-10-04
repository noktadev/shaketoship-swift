import SwiftUI

/// Values belong to the host's NavigationStack path.
public enum ShakeToShipRoute: Hashable {
  case ideas
  case idea(id: String)
  case inbox
}

#if canImport(UIKit)
  /// A plain list of entry points. Attach destinations to the host's stack.
  public struct ShakeToShipHub: View {
    public init() {}
    public var body: some View {
      FeedbackHubSurface { FeedbackHubView(model: $0) }
    }
  }
  public struct ShakeToShipIdeasList: View {
    public init() {}
    public var body: some View {
      FeedbackHubSurface(option: .ideas) { FeedbackIdeasView(model: $0) }
    }
  }
  public struct ShakeToShipIdeaDetail: View {
    public let id: String
    public init(id: String) { self.id = id }
    public var body: some View {
      FeedbackHubSurface(option: .ideas) { FeedbackIdeaDetail(model: $0, id: id).id(id) }
    }
  }
  public struct ShakeToShipSuggestSheet: View {
    public init() {}
    public var body: some View {
      FeedbackHubSurface(option: .ideas) { FeedbackSuggestView(model: $0) }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
  }
  public struct ShakeToShipInboxList: View {
    public init() {}
    public var body: some View {
      FeedbackHubSurface(option: .inbox) { FeedbackInboxView(model: $0) }
    }
  }
  public struct ShakeToShipEmailConsentCard: View {
    public init() {}
    public var body: some View {
      FeedbackHubSurface { FeedbackEmailOfferCard(model: $0, alwaysVisible: true) }
    }
  }
  public struct ShakeToShipEmailConsentSheet: View {
    public init() {}
    public var body: some View {
      FeedbackHubSurface { FeedbackEmailConsentPresentation(model: $0) }
    }
  }
  extension View {
    /// Install once inside the host's NavigationStack, outside lazy containers.
    /// The host supplies the optional Ideas action and owns its sheet presentation.
    public func shakeToShipDestinations(
      suggestLabel: String = "Suggest an idea", onSuggest: (() -> Void)? = nil
    ) -> some View {
      navigationDestination(for: ShakeToShipRoute.self) { route in
        switch route {
        case .ideas:
          ShakeToShipIdeasList().navigationTitle("Ideas")
            .toolbar {
              if let onSuggest {
                ToolbarItem(placement: .primaryAction) {
                  Button(suggestLabel, systemImage: "plus", action: onSuggest)
                }
              }
            }
        case .idea(let id): ShakeToShipIdeaDetail(id: id).navigationTitle("Idea")
        case .inbox: ShakeToShipInboxList().navigationTitle("Inbox")
        }
      }
    }
  }
  /// The inline offer waits for a tap before presenting the consent card.
  struct FeedbackEmailOfferCard: View {
    @Bindable var model: FeedbackHubModel
    var alwaysVisible = false
    @State private var hidden = false
    @State private var presented = false
    var body: some View {
      if !hidden && (alwaysVisible || model.showEmailOffer) {
        Group {
          if alwaysVisible {
            FeedbackEmailEnrollmentCard(model: model, onClose: close)
          } else {
            Button { presented = true } label: {
              FeedbackEntryLabel(title: "Get a reply", systemImage: "envelope")
            }.buttonStyle(.plain)
          }
        }
        .sheet(isPresented: $presented, onDismiss: close) {
          FeedbackEmailConsentPresentation(model: model)
        }
      }
    }
    private func close() { hidden = true; model.showEmailOffer = false }
  }
  struct FeedbackEmailConsentPresentation: View {
    @Bindable var model: FeedbackHubModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
      ScrollView { FeedbackEmailEnrollmentCard(model: model, onClose: { dismiss() }) }
        .feedbackCardPresentation()
    }
  }
  struct FeedbackEmailEnrollmentCard: View {
    @Bindable var model: FeedbackHubModel
    let onClose: () -> Void
    @State private var address = ""
    @State private var busy = false
    var body: some View {
      FeedbackCard(symbol: "envelope", title: "Get a reply",
        message: "Just so we can get back to you. We won't use your email for anything else.") {
        if let status = model.emailStatus, status.canUnsubscribe, status.delivery != "disabled" {
          Text(status.description).font(.subheadline).foregroundStyle(.secondary)
        }
        if let notice = model.emailNotice { Text(notice).font(.subheadline).feedbackPrimaryText() }
        if let error = model.error { Text(error).font(.footnote).feedbackPrimaryText() }
        if model.emailStatus.map({ $0.delivery != "disabled" }) == true {
          TextField("Email address", text: $address).textFieldStyle(.roundedBorder)
            .foregroundStyle(.primary).keyboardType(.emailAddress).textContentType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          FeedbackCardAction(title: "Notify me") {
            guard !busy else { return }
            let submitted = address
            busy = true
            model.error = nil
            Task {
              await model.enroll(submitted)
              if model.error == nil { address = "" }
              busy = false
            }
          }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else if let status = model.emailStatus {
          Text(status.description).font(.subheadline).foregroundStyle(.secondary)
        } else {
          ProgressView("Checking email settings…")
          Button("Try again") { Task { await model.refreshEmail() } }
        }
        Button("Not now", action: onClose).buttonStyle(.plain).frame(minHeight: 44)
      }.disabled(busy).task { await model.refreshEmail() }
    }
  }
  struct FeedbackEmailSheet: View {
    let model: FeedbackHubModel
    var body: some View {
      FeedbackEmailView(model: model)
    }
  }

  struct FeedbackRouteLink<Label: View>: View {
    let route: ShakeToShipRoute
    @ViewBuilder let label: () -> Label
    var body: some View { NavigationLink(value: route, label: label) }
  }

  /// The convenience entry owns one stack; routes push within the same sheet.
  struct FeedbackPromptSheet: View {
    /// Whether the composer can collect anything on this host (a note or an
    /// attachment). False leaves the sheet exactly as it was before the composer
    /// existed: Record, or not now.
    let showsWrite: Bool
    let hub: HubOptions
    let onHub: () -> Void
    let onIdeas: () -> Void
    let onInbox: () -> Void
    let onRecord: () -> Void
    let onWrite: () -> Void
    let onDismiss: () -> Void

    var body: some View {
      if hub.isEmpty {
        FeedbackRecordingConsentCard(showsWrite: showsWrite, onRecord: onRecord,
          onWrite: onWrite, onDismiss: onDismiss)
      } else {
        FeedbackHubSheet()
      }
    }
  }

  struct FeedbackRecordingConsentCard: View {
    let showsWrite: Bool
    let onRecord: () -> Void
    let onWrite: () -> Void
    let onDismiss: () -> Void
    var body: some View {
      ScrollView {
        FeedbackCard(symbol: "record.circle", title: "Report a bug",
          message: FeedbackRecordingCopy.promptExplanation) {
          FeedbackCardAction(title: "Record & report", action: onRecord)
          if showsWrite { Button("Write instead", action: onWrite).frame(minHeight: 44) }
          Button("Not now", action: onDismiss).buttonStyle(.plain).frame(minHeight: 44)
        }
      }.feedbackCardPresentation()
    }
  }

  struct FeedbackHubSheet: View {
    var initialRoute: ShakeToShipRoute? = nil
    var initialReport = false
    var screenshot: Data? = nil
    var body: some View {
      FeedbackHubSurface { model in
        if initialReport { FeedbackHubReport(model: model, screenshot: screenshot) }
        else { FeedbackHubEntryCard(model: model, path: initialRoute.map { [$0] } ?? []) }
      }
    }
  }

  struct FeedbackHubEntryCard: View {
    @Bindable var model: FeedbackHubModel
    @State var path: [ShakeToShipRoute] = []
    @State private var report: FeedbackReportPresentation?
    @State private var suggest = false
    @State private var email = false
    @State private var entryHeights: [String: CGFloat] = [:]
    @Environment(\.shakeToShipTheme) private var theme
    private var entryTitles: [String] {
      ["Report a bug"]
        + (model.config.hub.contains(.ideas) ? ["Suggest an idea", "Ideas"] : [])
        + (model.config.hub.contains(.inbox) ? ["Inbox"] : [])
    }
    var body: some View {
      NavigationStack(path: $path) {
        ScrollView {
          FeedbackCard(symbol: "bubble.left", title: "Any feedback to share?",
            message: "Report a problem, share an idea, or see what's new.") {
            if model.config.capabilities.contains(.screenRecording), FeedbackManualTrigger.isRecordingAvailable { FeedbackWalkthroughButton() }
            List {
              Section {
                Button {
                  report = FeedbackReportPresentation(screenshot: FeedbackReportScreenshot.captureForReport(model: model))
                } label: { entry("Report a bug", "ladybug", showsChevron: true) }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                if model.config.hub.contains(.ideas) {
                  Button { suggest = true } label: { entry("Suggest an idea", "lightbulb", showsChevron: true) }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                  NavigationLink(value: ShakeToShipRoute.ideas) { entry("Ideas", "arrow.up.square") }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
                if model.config.hub.contains(.inbox) {
                  NavigationLink(value: ShakeToShipRoute.inbox) { entry("Inbox", "tray") }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
              }
              .listRowBackground(theme.surface ?? Color(uiColor: .secondarySystemGroupedBackground))
            }
            .listStyle(.insetGrouped).scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, 44)
            .scrollContentBackground(.hidden).contentMargins(.vertical, 0, for: .scrollContent)
            .frame(height: entryTitles.reduce(0) { $0 + (entryHeights[$1] ?? 48) })
            // The native section supplies its own inset outside the card's content padding.
            .padding(.horizontal, -20)
            FeedbackRecordingDeviceHint()
            if !model.config.hub.contains(.inbox) {
              Button("Email updates", systemImage: "envelope") { email = true }
            }
          }
        }
        .navigationTitle("Feedback").toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: ShakeToShipRoute.self) { route in
          Group {
            switch route {
            case .ideas: ShakeToShipIdeasList().navigationTitle("Ideas")
            case .idea(let id): ShakeToShipIdeaDetail(id: id).navigationTitle("Idea")
            case .inbox: ShakeToShipInboxList().navigationTitle("Inbox")
            }
          }.navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        }
        .sheet(item: $report) { report in FeedbackHubReport(model: model, screenshot: report.screenshot) }
        .sheet(isPresented: $suggest) { FeedbackSuggestView(model: model) }
        .sheet(isPresented: $email) { FeedbackEmailSheet(model: model) }

      }.background(FeedbackSDKPresentationMarker())
        .feedbackTheme().feedbackCardPresentation(detents: [.medium, .large])
        .presentationBackground(theme.background ?? Color(uiColor: .systemGroupedBackground))
    }
    private func entry(_ title: String, _ symbol: String, showsChevron: Bool = false) -> some View {
      HStack(spacing: 12) {
        Image(systemName: symbol).foregroundStyle(.tint).frame(width: 28)
          .accessibilityHidden(true)
        Text(title).foregroundStyle(theme.primaryText ?? .primary).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
        if showsChevron {
          Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary).accessibilityHidden(true)
        }
      }
      .feedbackFont(.body, inherit: false).frame(minHeight: 24)
      .contentShape(Rectangle())
      .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 40 }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
        entryHeights[title] = max(44, height + 24)
      }
    }
  }
  struct FeedbackVoteButton: View {
    @Bindable var model: FeedbackHubModel
    let idea: FeedbackIdea
    var body: some View {
      Button {
        Task { await model.vote(idea) }
      } label: {
        FeedbackVoteLabel(idea: idea)
      }
      .buttonStyle(.borderless)
      .disabled(model.voting.contains(idea.id))
      .accessibilityLabel(idea.votedByMe ? "Remove your vote" : "Vote for this idea")
      .accessibilityValue("\(idea.voteCount) votes")
    }
  }
  struct FeedbackVoteLabel: View {
    let idea: FeedbackIdea
    var body: some View {
      VStack(spacing: 4) {
        Image(systemName: "arrow.up").fontWeight(.semibold)
        Text(idea.voteCount.formatted()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
      }
      .feedbackFont(.subheadline.weight(.semibold)).foregroundStyle(.tint)
      .frame(minWidth: 48, minHeight: 60)
      .background(.tint.opacity(idea.votedByMe ? 0.2 : 0.04), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(idea.votedByMe ? 0 : 0.25))
      }
    }
  }
  struct FeedbackEntryLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.shakeToShipTheme) private var theme
    var body: some View {
      HStack {
        Label {
          Text(title).feedbackPrimaryText().lineLimit(1).truncationMode(.tail)
        } icon: {
          Image(systemName: systemImage).foregroundStyle(.tint).frame(width: 28)
        }
        Spacer()
        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary).accessibilityHidden(true)
      }
      .feedbackFont(.body, inherit: false).frame(minHeight: 24)
    }
  }
#endif

/// Only SDK presentations use this shell. Embedded components retain host navigation.
struct FeedbackSheet<Content: View, Action: View>: View {
  let title: String
  var cancelDisabled = false
  @State var path: [ShakeToShipRoute] = []
  @ViewBuilder let content: () -> Content
  @ViewBuilder let action: () -> Action
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack(path: $path) {
      content()
        .navigationTitle(title)
        #if canImport(UIKit)
          .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { dismiss() }
              .disabled(cancelDisabled)
          }
          ToolbarItem(placement: .confirmationAction) { action() }
        }
    }
    .feedbackTheme().feedbackBackground()
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}

/// Mount this card only where a prompt may reserve an impression.
public struct ShakeToShipPromptCard: View {
  public init() {}
  public var body: some View {
    FeedbackHubSurface(option: .prompts) { model in
      VStack {
        if let prompt = model.prompt {
          FeedbackPromptCard(model: model, prompt: prompt)
        }
      }.task { await model.refreshPrompt() }
    }
  }
}

/// A host-controlled prompt card sheet. A closed sheet does not reserve an impression.
public struct ShakeToShipPromptPopover<Label: View>: View {
  @Binding private var isPresented: Bool
  private let label: Label
  public init(isPresented: Binding<Bool>, @ViewBuilder label: () -> Label) {
    _isPresented = isPresented
    self.label = label()
  }
  public var body: some View {
    FeedbackHubSurface(option: .prompts) { model in
      Button {
        isPresented = true
      } label: {
        label
      }
      .sheet(isPresented: $isPresented) {
        FeedbackPromptPopoverContent(model: model, isPresented: $isPresented)
      }
    }
  }
}
private struct FeedbackPromptPopoverContent: View {
  @Bindable var model: FeedbackHubModel
  @Binding var isPresented: Bool
  var body: some View {
    ScrollView {
      if let prompt = model.prompt {
        FeedbackPromptAnswerCard(model: model, prompt: prompt, onClose: { isPresented = false })
      } else {
        FeedbackCard(symbol: "bubble.left", title: "A question for you",
          message: model.promptLoading ? "Loading question…" : "No question is available.") {
          Button("Not now") { isPresented = false }.buttonStyle(.plain).frame(minHeight: 44)
        }
      }
    }
    #if canImport(UIKit)
    .feedbackCardPresentation()
    #endif
    .task { await model.refreshPrompt() }
  }
}

struct FeedbackHubSurface<Content: View>: View {
  var option: HubOptions?
  @ViewBuilder let content: (FeedbackHubModel) -> Content
  var body: some View {
    if let model = ShakeToShip.model, model.active,
      option.map({ model.config.hub.contains($0) }) ?? !model.config.hub.isEmpty
    {
      content(model).feedbackTheme().id(ObjectIdentifier(model)).id(model.revision)
    }
  }
}
