import Foundation
import Testing

@testable import ShakeToShip

private final class HubMemory: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Data?
  func read() -> Data? { lock.withLock { value } }
  func write(_ value: Data?) { lock.withLock { self.value = value } }
}
actor HubTestTransport: FeedbackTransport {
  var requests: [URLRequest] = []
  var responses: [(Int, String)] = []
  var suspended = false
  var pending: CheckedContinuation<Void, Never>?
  func prepare(_ responses: [(Int, String)], suspend: Bool = false) {
    self.responses = responses
    suspended = suspend
  }
  func resume() {
    suspended = false
    pending?.resume()
    pending = nil
  }
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let response = responses.isEmpty ? (200, "{}") : responses.removeFirst()
    if suspended { await withCheckedContinuation { pending = $0 } }
    return (
      Data(response.1.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!
    )
  }
  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
    try await perform(request)
  }
}

func hubIdentityJSON(_ id: String = "reporter", expires: TimeInterval = 4_000_000_000) -> String {
  let payload = Data("{\"exp\":\(expires)}".utf8).base64EncodedString()
  return "{\"reporterId\":\"\(id)\",\"reporterToken\":\"rt1.\(payload).signature\"}"
}

struct FeedbackHubClientTests {
  func fixture(
    transport: HubTestTransport, hub: HubOptions = [.ideas, .inbox, .prompts],
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 2_000_000_000) }
  ) throws -> (FeedbackHubClient, URL, FeedbackHubStorage) {
    let memory = HubMemory()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage = FeedbackHubStorage(
      scope: "test", root: root, readIdentity: { memory.read() },
      writeIdentity: { memory.write($0) })
    let config = ShakeToShipConfig(
      app: "com.example.test", collectorURL: URL(string: "https://ingest.example.test")!,
      secret: "project-secret", hub: hub)
    return (
      try FeedbackHubClient(
        config: config, storage: storage, transport: transport, now: now,
        sleep: { _ in throw CancellationError() }), root,
      storage
    )
  }
  @MainActor @Test func activationAndForegroundDoNotReserveUnpresentedPrompts() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (204, ""), (204, "")])
    let (client, root, _) = try fixture(transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    // Both activation and didBecomeActive call this same entry point.
    await model.start()
    await model.start()
    #expect(await transport.requests.map { $0.url!.path } == ["/identity"])
    #expect(model.prompt == nil)
  }

  @Test(arguments: [FeedbackOpsQueue.Operation.promptAnswer, .promptDismiss])
  func freshPresentationLoadsPendingDurablePromptOperations(_ operation: FeedbackOpsQueue.Operation)
    async throws
  {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (204, "")])
    let (original, root, storage) = try fixture(transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await original.setActive(true)
    try await original.enqueue(operation, target: "prompt", value: .string("served-or-answer"))
    let fresh = try FeedbackHubClient(
      config: await original.config, storage: storage, transport: transport,
      now: { Date(timeIntervalSince1970: 2_000_000_000) })
    await fresh.setActive(true)
    #expect(try await fresh.nextPrompt().isEmpty)
    #expect(await transport.requests.map { $0.url!.path } == ["/identity"])
  }

  @Test func presentationPrunesExpiredDurablePromptOperations() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (204, "")])
    let (original, root, storage) = try fixture(transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await original.setActive(true)
    try await original.enqueue(.promptAnswer, target: "prompt", value: .bool(true))
    let fresh = try FeedbackHubClient(
      config: await original.config, storage: storage, transport: transport,
      now: { Date(timeIntervalSince1970: 2_000_000_000 + 8 * 86400) })
    await fresh.setActive(true)
    #expect(try await fresh.nextPrompt().isEmpty)
    #expect(await transport.requests.map { $0.url!.path } == ["/identity", "/prompts/next"])
    let queue = try FeedbackOpsQueue(
      url: root.appendingPathComponent("ops.json"), reporterId: "reporter")
    #expect(queue.operations.isEmpty)
  }

  @Test func disabledMakesNoRequests() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try fixture(transport: transport, hub: [])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    await #expect(throws: FeedbackHubError.self) { try await client.identity() }
    await #expect(throws: FeedbackHubError.self) { try await client.replay() }
    await #expect(throws: FeedbackHubError.self) { try await client.nextPrompt() }
    #expect(await transport.requests.isEmpty)
  }
  @Test func resetRejectsUncooperativeInflightExchange() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())], suspend: true)
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let task = Task { try await client.identity() }
    while await transport.requests.isEmpty { await Task.yield() }
    let old = await client.generation
    try await client.reset()
    await transport.resume()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(await client.generation != old)
    await transport.prepare([(201, hubIdentityJSON("new"))])
    #expect(try await client.identity().reporterId == "new")
    #expect(await transport.requests.last?.value(forHTTPHeaderField: "x-reporter-token") == nil)
  }
  @Test func renewsOriginalTokenAndPersistsIdentity() async throws {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON(expires: 2_000_000_001)), (200, hubIdentityJSON()),
    ])
    let (client, root, storage) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let first = try await client.identity()
    let relaunched = try FeedbackHubClient(
      config: await client.config, storage: storage, transport: transport,
      now: { Date(timeIntervalSince1970: 2_000_000_000) })
    await relaunched.setActive(true)
    _ = try await relaunched.identity()
    #expect(
      await transport.requests.last?.value(forHTTPHeaderField: "x-reporter-token")
        == first.reporterToken)
  }
  @Test func captureBeforeExchangeCannotMoveAfterReset() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    await client.setActive(true)
    try await client.bindCapture(in: root)
    let binding = try #require(try FeedbackCaptureBinding.read(in: root))
    try await client.reset()
    await #expect(throws: FeedbackHubError.self) { try await client.captureIdentity(binding) }
    #expect(await transport.requests.isEmpty)
  }
  @Test func replayUsesDesiredStateAndSequenceAfterRestart() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, storage) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    try await client.enqueue(.vote, target: "idea", value: .bool(true))
    try await client.enqueue(.vote, target: "idea", value: .bool(false))
    let relaunched = try FeedbackHubClient(
      config: await client.config, storage: storage, transport: transport)
    await relaunched.setActive(true)
    try await relaunched.replay()
    let request = try #require(await transport.requests.last)
    #expect(request.httpMethod == "PUT")
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(body["voted"] as? Bool == false)
    #expect(body["seq"] as? Int == 2)
    #expect(body["app"] as? String == "com.example.test")
    #expect(await relaunched.pendingVotes().isEmpty)
  }
}

extension FeedbackHubClientTests {
  @Test func disablingGateRejectsAnInflightRead() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    _ = try await client.identity()
    await transport.prepare([(200, "{\"ideas\":[],\"nextCursor\":null}")], suspend: true)
    let task = Task { try await client.ideas(filter: "top") }
    while await transport.requests.count < 2 { await Task.yield() }
    await client.setActive(false)
    await transport.resume()
    await #expect(throws: (any Error).self) { try await task.value }
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("ideas-top.json").path))
  }
  @Test func authRejectionDropsOldQueueAndNeverTransfersOperations() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (401, "Unauthorized")])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    try await client.enqueue(.vote, target: "old", value: .bool(true))
    let generation = await client.generation
    await #expect(throws: (any Error).self) { try await client.replay() }
    #expect(await client.generation != generation)
    #expect(await client.pendingVotes().isEmpty)
    await transport.prepare([(201, hubIdentityJSON("new"))])
    try await client.replay()
    #expect(await transport.requests.count == 3)
  }
  @Test func retriesAreSerializedAndNewerVoteSurvivesInflightAck() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    try await client.enqueue(.vote, target: "idea", value: .bool(true))
    await transport.prepare([(200, "{}"), (200, "{}")], suspend: true)
    let replay = Task { try await client.replay() }
    while await transport.requests.count < 2 { await Task.yield() }
    try await client.enqueue(.vote, target: "idea", value: .bool(false))
    try await client.replay()
    #expect(await transport.requests.count == 2)
    await transport.resume()
    try await replay.value
    let requests = await transport.requests
    #expect(requests.count == 3)
    let body = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
    #expect(body["voted"] as? Bool == false)
    #expect(body["seq"] as? Int == 2)
  }
  @Test func transientBackoffAndPermanentGone() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (503, "Unavailable")])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    try await client.enqueue(.vote, target: "idea", value: .bool(true))
    try await client.replay()
    try await client.replay()
    #expect(await transport.requests.count == 2)
    #expect(await client.pendingVotes().first?.attempts == 1)
    // A new local desired state replaces the delayed operation, with a larger sequence.
    try await client.enqueue(.vote, target: "idea", value: .bool(false))
    await transport.prepare([(404, "Gone")])
    try await client.replay()
    #expect(await client.pendingVotes().isEmpty)
  }
  @Test func captureResponseIdIsBoundAndResetClearsIt() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    await client.setActive(true)
    try await client.bindCapture(in: root)
    let binding = try #require(try FeedbackCaptureBinding.read(in: root))
    let reporter = try await client.captureIdentity(binding)
    try await client.saveSessionRecord(
      "database-id", captureId: "external-id", binding: binding, reporter: reporter)
    #expect(try await client.ownedSessions().first?.id == "database-id")
    try await client.reset()
    #expect(try await client.ownedSessions().isEmpty)
    await #expect(throws: FeedbackHubError.self) {
      try await client.saveSessionRecord(
        "late-id", captureId: "external-id", binding: binding, reporter: reporter)
    }
  }
  @Test @MainActor func emailConflictRefreshesWithoutDeletingReplacement() async throws {
    let transport = HubTestTransport()
    let pending =
      #"{"delivery":"enabled","consent":"pending","pendingReplacement":false,"revision":1}"#
    let replacement =
      #"{"delivery":"enabled","consent":"verified","pendingReplacement":true,"revision":2}"#
    await transport.prepare([
      (201, hubIdentityJSON()), (200, pending), (409, #"{"error":"email_state_changed"}"#),
      (200, replacement),
    ])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    await model.refreshEmail()
    await model.unsubscribe()
    #expect(model.emailStatus?.revision == 2)
    #expect(model.emailStatus?.pendingReplacement == true)
    #expect(model.emailNotice?.contains("Review") == true)
    #expect(await transport.requests.filter { $0.httpMethod == "DELETE" }.count == 1)
    #expect(await transport.requests.allSatisfy { $0.url?.host == "ingest.example.test" })
  }
  @Test @MainActor func acceptedEmailDoesNotClaimDeliveryOrVerification() async throws {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON()), (202, #"{"accepted":true,"delivery":"enabled"}"#),
      (200, #"{"delivery":"enabled","consent":"pending","pendingReplacement":false,"revision":1}"#),
    ])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    await model.enroll("person@example.test")
    #expect(model.emailStatus?.consent == "pending")
    #expect(model.emailNotice == "Request received. Confirm your email when the message arrives.")
    let disabled = FeedbackEmailStatus(
      delivery: "disabled", consent: "verified", pendingReplacement: true, revision: 4)
    #expect(disabled.description == "Email updates are unavailable.")
    #expect(disabled.canUnsubscribe)
  }
}

extension FeedbackHubClientTests {
  @Test func cacheExpiresAfterFiveMinutesAndResetDeletesIt() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (200, #"{"ideas":[],"nextCursor":null}"#)])
    let (client, root, storage) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    _ = try await client.ideas(filter: "top")
    let offline = HubOfflineTransport()
    let fresh = try FeedbackHubClient(
      config: await client.config, storage: storage, transport: offline,
      now: { Date(timeIntervalSince1970: 2_000_000_299) })
    await fresh.setActive(true)
    #expect(try await fresh.ideas(filter: "top").ideas.isEmpty)
    let expired = try FeedbackHubClient(
      config: await client.config, storage: storage, transport: offline,
      now: { Date(timeIntervalSince1970: 2_000_000_301) })
    await expired.setActive(true)
    await #expect(throws: URLError.self) { try await expired.ideas(filter: "top") }
    try await client.reset()
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("ideas-top.json").path))
  }
  @Test func cachedPageCannotOverrideServerVisibilityFailure() async throws {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON()), (200, #"{"ideas":[],"nextCursor":null}"#), (404, "Unavailable"),
    ])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    _ = try await client.ideas(filter: "top")
    await #expect(throws: FeedbackHubError.self) { try await client.ideas(filter: "top") }
  }
  @Test @MainActor func expiredCursorRestartsWithoutReadingCursorContents() async throws {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON()), (400, #"{"error":"expired-cursor"}"#),
      (200, #"{"ideas":[],"nextCursor":"opaque-next"}"#),
    ])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    model.cursor = "opaque-expired"
    await model.refreshIdeas(more: true)
    #expect(model.cursor == "opaque-next")
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(
      URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains {
        $0.name == "cursor"
      } == false)
  }
  @Test func promptReplayUsesImpressionAndNeverReservesAnotherWhilePending() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (503, "Unavailable")])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    try await client.enqueue(.promptDismiss, target: "p", value: .string("served-impression"))
    try await client.replay()
    #expect(try await client.nextPrompt().isEmpty)
    let requests = await transport.requests
    #expect(requests.count == 2)
    let body = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
    #expect(body["impressionId"] as? String == "served-impression")
  }
}
private struct HubOfflineTransport: FeedbackTransport {
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw URLError(.notConnectedToInternet)
  }
  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
    throw URLError(.notConnectedToInternet)
  }
}

extension FeedbackHubClientTests {
  @Test func individualOptionsPreventOtherFeatureRequests() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try fixture(transport: transport, hub: [.inbox])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    await #expect(throws: FeedbackHubError.self) { try await client.request("ideas") }
    await #expect(throws: FeedbackHubError.self) { try await client.request("prompts/next") }
    #expect(await transport.requests.isEmpty)
  }
}

extension FeedbackHubClientTests {
  @Test @MainActor func identityResetStillClearsDataAfterRecorderUnmounts() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    try await client.enqueue(.vote, target: "old-account", value: .bool(true))
    let generation = await client.generation
    ShakeToShip.model = FeedbackHubModel(client: client, config: await client.config)
    ShakeToShip.deactivate()
    try await ShakeToShip.resetIdentity()
    #expect(await client.generation != generation)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ops.json").path))
    #expect(await transport.requests.count == 1)
    ShakeToShip.model = nil
  }
}

extension FeedbackHubClientTests {
  @Test @MainActor func automaticAuthResetClearsPrivateModelState() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (401, "Unauthorized")])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    await model.connect()
    model.emailStatus = FeedbackEmailStatus(
      delivery: "enabled", consent: "verified", pendingReplacement: false, revision: 1)
    model.prompt = FeedbackPrompt(
      id: "old", kind: "text", question: "private question", impressionId: "i")
    let revision = model.revision
    await #expect(throws: (any Error).self) {
      try await client.request("ideas/old/report", method: "POST")
    }
    #expect(model.revision != revision)
    #expect(model.emailStatus == nil)
    #expect(model.prompt == nil)
  }
  @Test func lateListCannotRepopulateModeratedCache() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    _ = try await client.identity()
    await transport.prepare([(200, #"{"ideas":[],"nextCursor":null}"#)], suspend: true)
    let request = Task { try await client.ideas(filter: "top") }
    while await transport.requests.count < 2 { await Task.yield() }
    try await client.invalidateVisibility()
    await transport.resume()
    await #expect(throws: FeedbackHubError.self) { try await request.value }
    #expect(
      !FileManager.default.fileExists(atPath: root.appendingPathComponent("ideas-top.json").path))
  }
  @Test func unexpiredIdentityStillQueuesOfflineDuringRenewalWindow() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON(expires: 2_000_000_100))])
    let (client, root, storage) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let original = try await client.identity()
    let offline = try FeedbackHubClient(
      config: await client.config, storage: storage, transport: HubOfflineTransport(),
      now: { Date(timeIntervalSince1970: 2_000_000_001) })
    await offline.setActive(true)
    #expect(try await offline.identity() == original)
    try await offline.enqueue(.vote, target: "idea", value: .bool(true))
    #expect(await offline.pendingVotes().count == 1)
  }
  @Test @MainActor func removingHubConfigurationRetiresPresentationAndRequests() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try fixture(transport: transport)
    defer {
      try? FileManager.default.removeItem(at: root)
      ShakeToShip.model = nil
    }
    await client.setActive(true)
    ShakeToShip.model = FeedbackHubModel(client: client, config: await client.config)
    let disabled = ShakeToShipConfig(
      app: "test", collectorURL: URL(string: "https://test.invalid")!, secret: "secret", hub: [])
    await ShakeToShip.activate(
      config: disabled, present: { _ in Issue.record("Disabled hub presented") })
    ShakeToShip.presentHub()
    #expect(ShakeToShip.model?.active == false)
    await #expect(throws: FeedbackHubError.self) { try await client.request("ideas") }
    #expect(await transport.requests.isEmpty)
  }
}

private final class HubReplayClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 2_000_000_000
  func now() -> Date { lock.withLock { Date(timeIntervalSince1970: time) } }
  func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}
extension FeedbackHubClientTests {
  @Test func replaySchedulesContinuationAndBoundsTransientAttempts() async throws {
    let transport = HubTestTransport()
    let (base, root, storage) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = HubReplayClock()
    let client = try FeedbackHubClient(
      config: await base.config, storage: storage, transport: transport,
      now: { clock.now() },
      sleep: { seconds in
        clock.advance(seconds)
        await Task.yield()
      })
    await client.setActive(true)
    await transport.prepare([(201, hubIdentityJSON())])
    for index in 0..<7 {
      try await client.enqueue(.vote, target: "idea-\(index)", value: .bool(true))
    }
    try await client.replay()
    while !(await client.pendingVotes().isEmpty) { await Task.yield() }
    #expect(await transport.requests.count == 8)
    await transport.prepare(Array(repeating: (503, "Unavailable"), count: 6))
    try await client.enqueue(.vote, target: "failing", value: .bool(true))
    try await client.replay()
    while await client.pendingVotes().first?.attempts ?? 0 < 5 { await Task.yield() }
    for _ in 0..<10 { await Task.yield() }
    #expect(await transport.requests.count == 13)
    #expect(await client.pendingVotes().first?.attempts == 5)
    await client.setActive(false)
  }
}

extension FeedbackHubClientTests {
  @Test @MainActor func emailOfferAppearsOnceAcrossResetAndNeverFromVoting() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (200, "{}")])
    let (client, root, _) = try fixture(transport: transport)
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
    }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config, defaults: defaults)
    let idea = FeedbackIdea(
      id: "idea", title: "A public idea", status: "open", voteCount: 0, votedByMe: false,
      replyExcerpt: nil)
    await model.vote(idea)
    #expect(!model.showEmailOffer)
    model.offerEmail()
    #expect(model.showEmailOffer)
    model.invalidate()
    model.offerEmail()
    #expect(!model.showEmailOffer)
    let relaunched = FeedbackHubModel(
      client: client, config: await client.config, defaults: defaults)
    relaunched.offerEmail()
    #expect(!relaunched.showEmailOffer)
  }
}

extension FeedbackHubClientTests {
  @Test @MainActor func suspendedPrivateOperationCannotUseReplacementIdentity() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try fixture(transport: transport)
    defer {
      try? FileManager.default.removeItem(at: root)
      ShakeToShip.model = nil
    }
    await client.setActive(true)
    let old = FeedbackHubModel(client: client, config: await client.config)
    ShakeToShip.model = old
    await old.connect()
    var release: CheckedContinuation<Void, Never>?
    let operation = Task { @MainActor in
      await old.perform {
        await withCheckedContinuation { release = $0 }
        _ = try await client.request(
          "ideas/old/details", method: "POST", fields: ["text": .string("private")])
      }
    }
    while release == nil { await Task.yield() }
    try await ShakeToShip.resetIdentity()
    release?.resume()
    await operation.value
    #expect(await transport.requests.isEmpty)
    #expect(!old.active)
    let replacement = try #require(ShakeToShip.model)
    #expect(replacement !== old)
    #expect(replacement.identityGeneration != old.identityGeneration)
    await transport.prepare([(201, hubIdentityJSON("new")), (200, "{}")])
    await replacement.perform { _ = try await client.request("ideas/new/details", method: "POST") }
    #expect(await transport.requests.count == 2)
  }

  @Test func concurrentRenewalFailureKeepsValidIdentityForEveryCaller() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON(expires: 2_000_000_100))])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let original = try await client.identity()
    await transport.prepare([(503, "Unavailable")], suspend: true)
    let first = Task { try await client.identity() }
    while await transport.requests.count < 2 { await Task.yield() }
    let second = Task { try await client.identity() }
    for _ in 0..<30 { await Task.yield() }
    await transport.resume()
    #expect(try await first.value == original)
    #expect(try await second.value == original)
    try await client.enqueue(.vote, target: "idea", value: .bool(true))
    #expect(await client.pendingVotes().count == 1)
    #expect(await transport.requests.count == 2)
  }

  @Test @MainActor func moderationInvalidatesSuggestionVisibility() async throws {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON()), (200, "{}"), (200, #"{"ideas":[],"nextCursor":null}"#),
    ])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    let visibility = model.visibilityRevision
    let idea = FeedbackIdea(
      id: "hidden", title: "Hidden", status: "open", voteCount: 0, votedByMe: false,
      replyExcerpt: nil)
    #expect(await model.moderate(idea, block: true))
    #expect(model.visibilityRevision != visibility)
    #expect(model.ideas.isEmpty)
  }
}

extension FeedbackHubClientTests {
  @Test @MainActor func failedDetailRefreshDoesNotKeepOldContent() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (404, "Not found")])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    model.selectedIdea = FeedbackIdea(
      id: "hidden", title: "Hidden", status: "open", voteCount: 0, votedByMe: false,
      replyExcerpt: nil)
    await model.detail("hidden")
    #expect(model.selectedIdea == nil)
    #expect(model.error != nil)
  }
}

extension FeedbackHubClientTests {
  @Test @MainActor func disabledModelDoesNotOfferEmailAfterLegacyReport() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try fixture(transport: transport)
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      defaults.removePersistentDomain(forName: suite)
      ShakeToShip.model = nil
    }
    let model = FeedbackHubModel(client: client, config: await client.config, defaults: defaults)
    ShakeToShip.model = model
    ShakeToShip.deactivate()
    model.offerEmail()
    #expect(!model.showEmailOffer)
    #expect(!defaults.bool(forKey: "shaketoship.email-offer.v3"))
  }
}

extension FeedbackHubClientTests {
  @Test @MainActor func deliveredSuggestionCannotRestoreContentAfterModeration() async throws {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON()), (200, "{}"), (200, #"{"ideas":[],"nextCursor":null}"#),
    ])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    let idea = FeedbackIdea(
      id: "hidden", title: "Hidden", status: "open", voteCount: 0, votedByMe: false,
      replyExcerpt: nil)
    // The request has already returned from the client. Its MainActor consumer runs later.
    let revision = model.revision
    let visibility = model.visibilityRevision
    let delivered = FeedbackSimilarIdeas(
      similar: [idea], threshold: 0.8, thresholdEvaluation: "fixture")
    var displayed: [FeedbackIdea] = []
    model.applyVisibleResponse(revision: revision, visibility: visibility) {
      displayed = delivered.similar
    }
    #expect(displayed.count == 1)
    #expect(await model.moderate(idea, block: true))
    displayed = []
    model.applyVisibleResponse(revision: revision, visibility: visibility) {
      displayed = delivered.similar
    }
    #expect(displayed.isEmpty)
    var unavailable = false
    model.applyVisibleResponse(revision: revision, visibility: visibility) { unavailable = true }
    #expect(!unavailable)
  }
}

extension FeedbackHubClientTests {
  /// Fixtures match merged routes/reporter-email.ts and contract/dtos.ts at f17bd37fe.
  @Test @MainActor func disabledEmailEnrollmentKeepsConsentAndUsesObservedClearRevision()
    async throws
  {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON()),
      (202, #"{"accepted":false,"delivery":"disabled"}"#),
      (
        200, #"{"delivery":"disabled","consent":"verified","pendingReplacement":true,"revision":7}"#
      ),
      (200, #"{"cleared":true}"#),
      (200, #"{"delivery":"disabled","consent":"none","pendingReplacement":false,"revision":8}"#),
    ])
    let (client, root, _) = try fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    await model.enroll("person@example.test")
    #expect(model.emailNotice == "Email updates are unavailable.")
    #expect(model.emailStatus?.canUnsubscribe == true)
    #expect(model.emailStatus?.pendingReplacement == true)
    await model.unsubscribe()
    #expect(model.emailStatus?.consent == "none")
    let requests = await transport.requests.filter { $0.url?.path == "/reporter/email" }
    #expect(requests.count == 4)
    #expect(
      requests.allSatisfy {
        $0.value(forHTTPHeaderField: "x-feedback-secret") == "project-secret"
          && $0.value(forHTTPHeaderField: "x-reporter-token") != nil
      })
    let clear = try #require(requests.first { $0.httpMethod == "DELETE" })
    let body = try JSONSerialization.jsonObject(with: clear.httpBody!) as! [String: Any]
    #expect(Set(body.keys) == ["app", "revision"])
    #expect(body["app"] as? String == "com.example.test")
    #expect(body["revision"] as? Int == 7)
    #expect(
      requests.filter { $0.httpMethod == "GET" }.allSatisfy {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems == [
          URLQueryItem(name: "app", value: "com.example.test")
        ]
      })
  }
}
