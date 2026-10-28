import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct FeedbackSupportSummary: Decodable, Identifiable, Sendable {
  let id: String
  let messages: [FeedbackConversationSnapshot.Message]
  let updatedAt: String
  var readThrough: Int
  var unread: Int
}
struct FeedbackSupportCapabilities: Decodable, Sendable {
  let asyncAdmission: Bool
  let liveDelivery: Bool
  let foregroundBanners: Bool
}
struct FeedbackSupportPage: Decodable, Sendable {
  let conversations: [FeedbackSupportSummary]
  let nextCursor: String?
  let unreadTotal: Int?
}
struct FeedbackSupportEvents: Codable, Sendable {
  struct Event: Codable, Sendable {
    let sequence: Int
    let conversationId: String
    let revision: Int
  }
  let events: [Event]
  let cursor: Int
  let hasMore: Bool
  let resync: Bool
}

extension FeedbackHubClient {
  func supportCapabilities() async throws -> FeedbackSupportCapabilities {
    try await decode(FeedbackSupportCapabilities.self, path: "v3/support/capabilities")
  }
  func supportEvents() async throws -> FeedbackSupportEvents {
    let expected = localGeneration
    let cursor = try storage.read(Int.self, file: "support-cursor.json")
    let result = try await decode(FeedbackSupportEvents.self, path: "v3/support/events",
      query: [.init(name: "after", value: String(cursor ?? 0)), .init(name: "initial", value: cursor == nil ? "true" : "false")])
    guard expected == localGeneration, result.cursor >= 0 else { throw FeedbackHubError.identityChanged }
    return result
  }
  func acknowledgeSupportEvents(_ events: FeedbackSupportEvents) throws {
    _ = try ownedSessions()
    try storage.write(events.cursor, file: "support-cursor.json")
  }
  func supportConversations(before: String? = nil) async throws -> FeedbackSupportPage {
    try await decode(FeedbackSupportPage.self, path: "v3/conversations",
      query: before.map { [.init(name: "before", value: $0)] } ?? [])
  }
  func readSupport(_ id: String, through: Int) async throws {
    guard UUID(uuidString: id) != nil else { throw FeedbackHubError.invalidResponse }
    _ = try await request("v3/conversations/\(id)/read", method: "POST", fields: ["through": .integer(through)])
  }
}

#if canImport(UIKit)
import SwiftUI

extension FeedbackHubModel {
  func loadOlderSupportConversations() async {
    guard active, let cursor = supportHistoryCursor else { return }
    do {
      let page = try await client.supportConversations(before: cursor)
      guard active, identityGeneration == client.localGeneration else { return }
      let merged = Dictionary((supportConversations + page.conversations).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
      supportConversations = merged.values.sorted { $0.updatedAt > $1.updatedAt }
      supportHistoryCursor = page.nextCursor == cursor ? nil : page.nextCursor
      supportUnreadTotal = page.unreadTotal ?? supportConversations.reduce(0) { $0 + $1.unread }
    } catch { self.error = "Could not load older conversations. Please try again." }
  }
  func receiveSupportUpdates() async {
    guard active, config.hub.contains(.support) else { return }
    while !Task.isCancelled && active {
      do {
        // Subscribe before catch-up. URLSession buffers hints during the REST reads.
        let capabilities = try await client.supportCapabilities()
        supportBannersEnabled = capabilities.foregroundBanners
        let connected: Bool
        if capabilities.liveDelivery { connected = (try? await client.openSupportSocket()) != nil }
        else { await client.closeSupportSocket(); connected = false }
        let events = try await client.supportEvents()
        let page = try await client.supportConversations()
        let summaries = page.conversations
        try Task.checkCancellation()
        guard active, identityGeneration == client.localGeneration else { return }
        let previous = Dictionary(uniqueKeysWithValues: supportConversations.map { ($0.id, $0.messages.last(where: { $0.role == "assistant" })?.id) })
        let merged = Dictionary((supportConversations + summaries).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        supportConversations = merged.values.sorted { $0.updatedAt > $1.updatedAt }
        supportUnreadTotal = page.unreadTotal ?? supportConversations.reduce(0) { $0 + $1.unread }
        if supportHistoryCursor == nil || events.resync { supportHistoryCursor = page.nextCursor }
        let changed = Set(events.events.map(\.conversationId))
        if !events.resync, let latest = summaries.sorted(by: { $0.updatedAt > $1.updatedAt }).first(where: { $0.unread > 0 && changed.contains($0.id) && $0.id != visibleConversationID && $0.messages.last(where: { $0.role == "assistant" })?.id != (previous[$0.id] ?? nil) }) {
          supportReplyConversationID = latest.id
        }
        // Fetch and merge before persisting the notification watermark.
        if let current = try? await client.loadConversation(), current.snapshot != nil,
          (events.resync || changed.contains(current.id)) {
          _ = try await client.refreshConversation(current)
          supportRevision = UUID()
        }
        try await client.acknowledgeSupportEvents(events)
        if events.hasMore { continue }
        if connected { try await client.waitForSupportHint() }
        else { try await Task.sleep(for: .seconds(Double.random(in: 13...17))) }
      } catch is CancellationError { return }
      catch FeedbackHubError.http(404, _, _) { return } // Installed older backend.
      catch {
        do { try await Task.sleep(for: .seconds(Double.random(in: 13...17))) } catch { return }
      }
    }
    await client.closeSupportSocket()
  }
}

struct FeedbackSupportHost: View {
  @Bindable var model: FeedbackHubModel
  let mayPresent: Bool
  let open: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    ZStack {
      Color.clear.frame(width: 0, height: 0)
      if scenePhase == .active, model.supportBannersEnabled, model.supportReplyConversationID != nil {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
      if mayPresent, model.supportBannersEnabled, model.supportReplyConversationID != nil, !model.config.screenshotExclusion(), ShakeToShip.hostWindow?.rootViewController?.presentedViewController == nil {
        Button(action: open) {
          Label("Support replied", systemImage: "bubble.left.fill")
            .font(.callout.weight(.semibold)).padding(14)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("support-reply-banner")
        .padding(.top, 8)
      }
      }
      }
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { await model.client.closeSupportSocket(); return }
      await model.receiveSupportUpdates()
    }
  }
}
#endif
