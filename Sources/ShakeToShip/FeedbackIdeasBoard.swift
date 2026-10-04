#if canImport(UIKit)
import SwiftUI

/// The mounted screen uses the same model and routes as the headless list.
struct FeedbackIdeasBoard: View {
  @Bindable var model: FeedbackHubModel
  @State private var suggest = false
  @State private var promptPresented = false
  @Environment(\.shakeToShipTheme) private var theme
  private var background: Color { theme.background ?? Color(uiColor: .systemBackground) }
  var body: some View {
    List {
      Group {
        Section {
          Text("Vote for a change. Help decide what’s next.")
            .feedbackFont(.subheadline, inherit: false).foregroundStyle(theme.secondaryText ?? .secondary)
            .lineLimit(3)
          Picker("Ideas order", selection: $model.filter) {
            Text("Top").tag("top")
            Text("New").tag("new")
            Text("Planned").tag("planned")
            if model.filter == "shipped" { Text("Shipped").tag("shipped") }
            if model.filter == "mine" { Text("Mine").tag("mine") }
          }.pickerStyle(.segmented).padding(.vertical, 8)
        }.listRowSeparator(.hidden)
        FeedbackHubErrorSection(model: model)
        if model.showEmailOffer { FeedbackEmailOfferCard(model: model) }
        if let prompt = model.prompt, model.config.hub.contains(.prompts) {
          ShakeToShipPromptPopover(isPresented: $promptPresented) {
            HStack(spacing: 12) {
              Image(systemName: "bubble.left")
              Text(prompt.question).feedbackFont(.subheadline, inherit: false).lineLimit(2)
              Spacer(minLength: 0)
              Image(systemName: "chevron.right").font(.caption)
            }.frame(minHeight: 44).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityIdentifier("ShakeToShip.ideas.question")
        }
        if model.loading && model.ideas.isEmpty {
          ProgressView("Loading ideas…").frame(maxWidth: .infinity, minHeight: 200).listRowSeparator(.hidden)
        } else if model.ideas.isEmpty {
          VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 44, weight: .ultraLight))
              .foregroundStyle(theme.accent ?? .accentColor)
            Text(model.error == nil ? "A good idea starts here" : "Ideas are unavailable")
              .feedbackFont(.title2.weight(.semibold), inherit: false).lineLimit(3)
            Text(model.error == nil ? "What would make this app better for you? Share it with the team."
              : "Check your connection and try again.")
              .feedbackFont(.subheadline, inherit: false).foregroundStyle(theme.secondaryText ?? .secondary)
              .lineLimit(4)
            if model.error != nil { Button("Try again") { Task { await model.refreshIdeas() } }.frame(minHeight: 44) }
          }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 56)
            .listRowSeparator(.hidden)
        } else {
          ForEach(model.ideas) { idea in
            HStack(alignment: .top, spacing: 20) {
              FeedbackVoteButton(model: model, idea: idea)
              FeedbackRouteLink(route: .idea(id: idea.id)) {
                VStack(alignment: .leading, spacing: 10) {
                  Text(idea.title).feedbackFont(.headline, inherit: false)
                    .foregroundStyle(theme.primaryText ?? .primary).lineLimit(2)
                  if let text = idea.body ?? idea.replyExcerpt {
                    Text(text).feedbackFont(.subheadline, inherit: false)
                      .foregroundStyle(theme.secondaryText ?? .secondary).lineLimit(2)
                  }
                  FeedbackStatusChip(idea: idea)
                }.frame(maxWidth: .infinity, alignment: .leading)
              }
            }.padding(.vertical, 16).alignmentGuide(.listRowSeparatorLeading) { _ in 68 }
          }
          if model.cursor != nil { Button("More ideas") { Task { await model.refreshIdeas(more: true) } } }
        }
      }.listRowBackground(background)
        .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
    }
    .listStyle(.plain).listRowSpacing(0).scrollContentBackground(.hidden)
    .background(background).foregroundStyle(theme.primaryText ?? .primary)
    .background(FeedbackNativeNavigationTheme())
    .safeAreaInset(edge: .bottom) {
      Button { suggest = true } label: {
        Label("Suggest an idea", systemImage: "plus").fontWeight(.semibold).lineLimit(1)
          .frame(maxWidth: .infinity, minHeight: 50)
          .foregroundStyle(.white)
          .background(theme.accent ?? .accentColor, in: RoundedRectangle(cornerRadius: 14))
      }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 12).background(background)
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button("Shipped") { model.filter = "shipped" }
          Button("My ideas") { model.filter = "mine" }
          if let url = model.config.supportURL { Link("Contact the team", destination: url) }
        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More ideas options")
      }
    }
    .task {
      if model.ideas.isEmpty { await model.refreshIdeas() }
      await model.refreshPrompt()
    }
    .refreshable { await model.refreshIdeas() }
    .onChange(of: model.filter) { _, _ in Task { await model.refreshIdeas() } }
    .sheet(isPresented: $suggest) { FeedbackSuggestView(model: model) }
  }
}
#endif
