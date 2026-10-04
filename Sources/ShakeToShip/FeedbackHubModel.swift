import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class FeedbackHubModel {
  let client: FeedbackHubClient
  let config: ShakeToShipConfig
  let identityGeneration: UUID
  let draftStore: FeedbackReportDraftStore
  var active = true
  var revision = UUID()
  var visibilityRevision = UUID()
  var ideas: [FeedbackIdea] = []
  var inbox: [FeedbackInboxMessage] = []
  var prompt: FeedbackPrompt?
  var emailStatus: FeedbackEmailStatus?
  var emailNotice: String?
  var showEmailOffer = false
  private var listRequest = UUID()
  private(set) var promptLoading = false
  var loading = false
  var inboxLoading = false
  var inboxError: String?
  var error: String?
  var filter = "top"
  var cursor: String?
  var selectedTab = 0
  var reportScreenshot: Data?
  func endReportPresentation() { reportScreenshot = nil }
  var selectedIdea: FeedbackIdea?
  var detailLoading = false
  private var detailRequest = UUID()
  var voting: Set<String> = []
  var sessions: [FeedbackOwnedSession] = []
  private let defaults: UserDefaults
  private let emailOfferKey: String

  init(client: FeedbackHubClient, config: ShakeToShipConfig, defaults: UserDefaults = .standard) {
    self.client = client
    self.identityGeneration = client.localGeneration
    self.draftStore = FeedbackReportDraftStore(storage: client.storage, generation: client.localGeneration)
    self.config = config
    self.defaults = defaults
    emailOfferKey = "shaketoship.email-offer.v3"
  }
  func invalidate() {
    if FeedbackManualTrigger.reportRecording?.store.generation == identityGeneration {
      FeedbackManualTrigger.reportRecording = nil
    }
    loading = false
    promptLoading = false
    listRequest = UUID()
    inboxLoading = false
    inboxError = nil
    revision = UUID()
    reportScreenshot = nil
    ideas = []
    inbox = []
    prompt = nil
    emailStatus = nil
    emailNotice = nil
    showEmailOffer = false
    error = nil
    selectedIdea = nil
    detailRequest = UUID()
    detailLoading = false
    voting = []
    sessions = []
    cursor = nil
  }
  static let identityResetNotification = Notification.Name("shaketoship.identity-reset")
  func connect() async {
    let owner = ObjectIdentifier(client)
    await client.observeReset { [weak self] in
      let current = ShakeToShip.model
      let target = current.map { ObjectIdentifier($0.client) == owner } == true ? current : self
      if let target {
        let wasActive = target.active
        target.invalidate()
        target.active = false
        if current === target {
          let replacement = FeedbackHubModel(
            client: target.client, config: target.config, defaults: target.defaults)
          replacement.active = wasActive
          ShakeToShip.model = replacement
        }
      }
      NotificationCenter.default.post(name: Self.identityResetNotification, object: nil)
    }
  }
  func perform(_ operation: @MainActor () async throws -> Void) async {
    guard active else { return }
    let expected = revision
    let generation = identityGeneration
    await connect()
    guard expected == revision, active else { return }
    do {
      try await FeedbackHubOperationContext.$generation.withValue(generation) {
        try await operation()
      }
    } catch {
      guard expected == revision, active else { return }
      if error as? FeedbackHubError == .visibilityChanged { return }
      if error as? FeedbackHubError == .authentication
        || error as? FeedbackHubError == .identityChanged
      {
        invalidate()
      }
      self.error = error.localizedDescription
    }
  }
  func start() async {
    await perform {
      try await client.replay()
      await refreshIdeas()
      if config.hub.contains(.inbox) { await refreshInbox() }
    }
  }
  func refreshIdeas(more: Bool = false) async {
    guard config.hub.contains(.ideas), !more || !loading else { return }
    loading = true
    let expected = revision
    let requestedFilter = filter
    let requestID = UUID()
    listRequest = requestID
    defer { if expected == revision, listRequest == requestID { loading = false } }
    await perform {
      let page: FeedbackIdeaPage
      do {
        page = try await client.ideas(filter: requestedFilter, cursor: more ? cursor : nil)
      } catch FeedbackHubError.http(400, let body, _)
        where more
        && (try? JSONDecoder().decode(FeedbackErrorDTO.self, from: Data(body.utf8)).error)
          == "expired-cursor"
      {
        page = try await client.ideas(filter: requestedFilter)
        guard expected == revision, requestedFilter == filter, listRequest == requestID else {
          return
        }
        ideas = []
      }
      guard expected == revision, requestedFilter == filter, listRequest == requestID, active else {
        return
      }
      ideas =
        more
        ? ideas + page.ideas.filter { incoming in !ideas.contains { $0.id == incoming.id } }
        : page.ideas
      let pending = await client.pendingVotes()
      guard expected == revision, active, listRequest == requestID else { return }
      for op in pending {
        if case .bool(let voted) = op.desiredState,
          let i = ideas.firstIndex(where: { $0.id == op.targetId })
        {
          if ideas[i].votedByMe != voted { ideas[i].voteCount += voted ? 1 : -1 }
          ideas[i].votedByMe = voted
        }
      }
      cursor = page.nextCursor
      error = nil
    }
  }
  func detail(_ id: String) async {
    let expected = revision
    let visibility = visibilityRevision
    let requestID = UUID()
    detailRequest = requestID
    selectedIdea = nil
    sessions = []
    detailLoading = true
    defer { if expected == revision, detailRequest == requestID { detailLoading = false } }
    await perform {
      do {
        let value = try await client.decode(FeedbackIdea.self, path: "ideas/\(id)")
        let owned = try await client.attachableReports()
        guard expected == revision, active else { return }
        guard visibility == visibilityRevision, detailRequest == requestID, !Task.isCancelled else {
          return
        }
        selectedIdea = value
        sessions = owned
      } catch {
        guard detailRequest == requestID, !Task.isCancelled else { return }
        throw error
      }
    }
  }
  func vote(_ input: FeedbackIdea) async {
    guard !voting.contains(input.id) else { return }
    let idea =
      selectedIdea?.id == input.id
      ? selectedIdea! : ideas.first(where: { $0.id == input.id }) ?? input
    voting.insert(idea.id)
    defer { voting.remove(idea.id) }
    let expected = revision
    await perform {
      try await client.enqueue(.vote, target: idea.id, value: .bool(!idea.votedByMe))
      guard expected == revision else { return }
      func toggled(_ input: FeedbackIdea) -> FeedbackIdea {
        var value = input
        value.votedByMe = !idea.votedByMe
        value.voteCount = max(0, input.voteCount + (value.votedByMe ? 1 : -1))
        return value
      }
      if let i = ideas.firstIndex(where: { $0.id == idea.id }) { ideas[i] = toggled(ideas[i]) }
      if selectedIdea?.id == idea.id { selectedIdea = selectedIdea.map(toggled) }
      voting.remove(idea.id)
      try await client.replay()
    }
  }
  func refreshInbox() async {
    guard active, config.hub.contains(.inbox), !inboxLoading else { return }
    let expected = revision
    inboxLoading = true
    defer { if expected == revision { inboxLoading = false } }
    await perform {
      do {
        let result = try await client.decode(FeedbackInbox.self, path: "v2/inbox")
        guard expected == revision, active else { return }
        inbox = result.messages
        inboxError = nil
      } catch {
        if expected == revision, active { inboxError = error.localizedDescription }
        throw error
      }
    }
  }
  func acknowledge(_ message: FeedbackInboxMessage) async {
    let expected = revision
    await perform {
      try await client.acknowledge([message.id])
      guard expected == revision else { return }
      inbox.removeAll { $0.id == message.id }
    }
  }
  /// Reserve only from a mounted, eligible presentation surface. Never call from activation/replay.
  func refreshPrompt() async {
    guard active, !Task.isCancelled, config.hub.contains(.prompts), prompt == nil, !promptLoading
    else { return }
    promptLoading = true
    let expected = revision
    defer { if expected == revision { promptLoading = false } }
    await perform {
      let data = try await client.nextPrompt()
      guard expected == revision, active else { return }
      prompt = data.isEmpty ? nil : try JSONDecoder().decode(FeedbackPrompt.self, from: data)
    }
  }
  func respond(_ prompt: FeedbackPrompt, value: FeedbackHubValue?, dismiss: Bool = false) async {
    let expected = revision
    await perform {
      if !dismiss {
        guard let value, prompt.accepts(value) else { throw FeedbackHubError.invalidPromptAnswer }
      }
      try await client.enqueue(
        dismiss ? .promptDismiss : .promptAnswer, target: prompt.id,
        value: dismiss ? .string(prompt.impressionId) : value!)
      guard expected == revision else { return }
      self.prompt = nil
      try await client.replay()
    }
  }
  func offerEmail(after expected: UUID? = nil) {
    guard FeedbackGate.shouldAttachHub(config: config, recorderActive: active),
      expected == nil || expected == revision
    else { return }
    guard !defaults.bool(forKey: emailOfferKey) else { return }
    defaults.set(true, forKey: emailOfferKey)
    showEmailOffer = true
  }
  func refreshEmail() async {
    let expected = revision
    await perform {
      let status = try await client.decode(FeedbackEmailStatus.self, path: "reporter/email")
      guard expected == revision, active else { return }
      emailStatus = status
    }
  }
  func enroll(_ email: String) async {
    let expected = revision
    await perform {
      let response = try await client.decode(
        FeedbackEmailEnrollment.self, path: "reporter/email", method: "POST",
        fields: ["email": .string(email)])
      guard expected == revision else { return }
      emailNotice =
        response.accepted && response.delivery == "enabled"
        ? "Request received. Confirm your email when the message arrives."
        : "Email updates are unavailable."
      await refreshEmail()
    }
  }
  func unsubscribe() async {
    guard let status = emailStatus else { return }
    let expected = revision
    await perform {
      do {
        _ = try await client.request(
          "reporter/email", method: "DELETE", fields: ["revision": .integer(Int(status.revision))])
        guard expected == revision else { return }
        emailNotice = "Email updates are off."
      } catch FeedbackHubError.http(409, _, _) {
        guard expected == revision else { return }
        emailNotice = "Your email settings changed. Review them before you unsubscribe again."
      }
      await refreshEmail()
    }
  }
  /// Validate again on MainActor when a client response reaches view state.
  func applyVisibleResponse(revision expected: UUID, visibility: UUID, _ apply: () -> Void) {
    guard active, expected == revision, visibility == visibilityRevision else { return }
    apply()
  }
  func moderate(_ idea: FeedbackIdea, block: Bool) async -> Bool {
    let expected = revision
    var hidden = false
    await perform {
      _ = try await client.request(
        "ideas/\(idea.id)/\(block ? "block-author" : "report")", method: "POST",
        fields: block ? [:] : ["reason": .string("Inappropriate content")])
      guard expected == revision else { return }
      ideas = []
      selectedIdea = nil
      cursor = nil
      visibilityRevision = UUID()
      listRequest = UUID()
      await refreshIdeas()
      hidden = true
    }
    return hidden
  }

}

/// Public entry points use only the currently mounted recorder. No singleton bootstrap occurs for disabled hosts.
@MainActor
public enum ShakeToShip {
  static var model: FeedbackHubModel? {
    get { FeedbackHubRuntime.shared.model }
    set { FeedbackHubRuntime.shared.model = newValue }
  }
  #if canImport(UIKit)
  static weak var hostWindow: UIWindow?
  #endif
  static var present: ((Int) -> Void)?
  private static var activation = UUID()
  /// Cached unread messages from the last inbox fetch. Never performs network I/O.
  /// Returns zero before a fetch, after identity reset, and while the hub is inactive.
  public static var unreadInboxCount: Int {
    get async { cachedUnreadInboxCount }
  }
  /// Observable from SwiftUI bodies, including acknowledgement and identity changes.
  public static var hasUnreadInboxReplies: Bool { cachedUnreadInboxCount > 0 }
  private static var cachedUnreadInboxCount: Int {
    guard let model, model.active, model.config.hub.contains(.inbox) else { return 0 }
    return model.inbox.count
  }
  public static func presentHub() {
    guard let model, model.active else { return }
    #if canImport(UIKit)
    model.reportScreenshot = FeedbackReportScreenshot.capture(config: model.config)
    #endif
    present?(0)
    Task { await model.start() }
  }
  /// Captures the host before any SDK sheet opens. The user reviews it before sending.
  public static func presentReport() {
    guard let model, model.active else { return }
    #if canImport(UIKit)
    model.reportScreenshot = FeedbackReportScreenshot.capture(config: model.config)
    #endif
    present?(3)
  }
  /// Presents Ideas over the mounted host window in a full-screen window.
  public static func presentIdeas() {
    guard let model, model.active, model.config.hub.contains(.ideas) else { return }
    present?(4)
  }
  public static func resetIdentity() async throws {
    guard let model else {
      try FeedbackHubStorage.clearAllLocalIdentities()
      return
    }
    model.invalidate()
    try await model.client.reset()
  }
  static func activate(config: ShakeToShipConfig, present: @escaping (Int) -> Void) async {
    deactivate()
    guard FeedbackGate.shouldAttachHub(config: config, recorderActive: true) else { return }
    let expected = UUID()
    activation = expected
    do {
      let client = try FeedbackHubClient(config: config, storage: .live(config: config))
      let model = FeedbackHubModel(client: client, config: config)
      self.model = model
      self.present = present
      await model.connect()
      await client.setActive(true)
      guard activation == expected, model.active else {
        await client.setActive(false)
        return
      }
      await model.start()
    } catch { /* Storage failure leaves the hub absent. */  }
  }
  static func deactivate() {
    activation = UUID()
    guard let model else { return }
    model.active = false
    model.invalidate()
    NotificationCenter.default.post(name: FeedbackHubModel.identityResetNotification, object: nil)
    present = nil
    model.client.disableImmediately()
  }
  static func client(for config: ShakeToShipConfig) -> FeedbackHubClient? {
    guard let model, model.active, model.config.app == config.app,
      model.config.secret == config.secret, model.config.collectorURL == config.collectorURL
    else { return nil }
    return model.client
  }
  static func canAccessCapture(in directory: URL, allowLegacy: Bool = true) async -> Bool {
    do {
      guard let binding = try FeedbackCaptureBinding.read(in: directory) else {
        return allowLegacy && (model?.active != true || model?.config.allowsLegacyCaptures == true)
      }
      guard let model, model.active else { return false }
      let expected = model.revision
      let allowed = await model.client.ownsCapture(binding)
      return allowed && model.active && expected == model.revision && self.model === model
    } catch { return false }
  }
  public static func promptBanner() -> some View { FeedbackPromptBanner() }
}

@MainActor @Observable
private final class FeedbackHubRuntime {
  static let shared = FeedbackHubRuntime()
  var model: FeedbackHubModel?
}
private struct FeedbackPromptBanner: View {
  var body: some View { ShakeToShipPromptCard() }
}
