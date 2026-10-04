import Foundation
import Testing

@testable import ShakeToShip

/// Bodies and statuses follow the merged SDK prompt handler at 7a1be2374.
/// These injected responses verify client behavior, not server transactions.
@MainActor
struct FeedbackPromptContractTests {
  static let promptID = "c0000000-0000-4000-8000-000000000001"
  static let impressionID = "d0000000-0000-4000-8000-000000000001"
  static let promptJSON =
    #"{"id":"c0000000-0000-4000-8000-000000000001","kind":"text","question":"What would help?","impressionId":"d0000000-0000-4000-8000-000000000001"}"#

  @Test(arguments: [
    String(repeating: "a", count: 1999) + "🙂", String(repeating: "e\u{0301}", count: 1001),
    "\u{FEFF}",
  ])
  func invalidUnicodeAnswerKeepsPromptAndNeverEntersQueue(_ text: String) async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (400, #"{"error":"invalid-request"}"#)])
    let (client, root, _) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    _ = try await client.identity()
    let model = FeedbackHubModel(client: client, config: await client.config)
    let prompt = try JSONDecoder().decode(FeedbackPrompt.self, from: Data(Self.promptJSON.utf8))
    model.prompt = prompt
    await model.respond(prompt, value: .string(text))
    #expect(model.prompt?.id == prompt.id)
    #expect(model.error != nil)
    #expect(await transport.requests.count == 1)
    let queue = try FeedbackOpsQueue(
      url: root.appendingPathComponent("ops.json"), reporterId: "reporter")
    #expect(queue.operations.isEmpty)
  }

  @Test(arguments: [
    String(repeating: "a", count: 1998) + "🙂", String(repeating: "e\u{0301}", count: 1000),
  ])
  func exactServerUnicodeBoundarySubmitsWithoutChangingText(_ text: String) async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (200, #"{"answered":true}"#)])
    let (client, root, _) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    let prompt = try JSONDecoder().decode(FeedbackPrompt.self, from: Data(Self.promptJSON.utf8))
    model.prompt = prompt
    await model.respond(prompt, value: .string(text))
    #expect(model.prompt == nil)
    #expect(model.error == nil)
    let request = try #require(await transport.requests.last)
    let body = try JSONDecoder().decode([String: FeedbackHubValue].self, from: request.httpBody!)
    #expect(body["value"] == .string(text))
  }

  @Test func empty204DoesNotDecodeOrPoll() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (204, "")])
    let (client, root, _) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    await model.refreshPrompt()
    await model.start()
    #expect(model.prompt == nil)
    #expect(model.error == nil)
    #expect(await transport.requests.count == 2)
  }

  @Test(arguments: [FeedbackHubValue.bool(true), .integer(4), .string("  More filters\n")])
  func typedAnswersAndReplayKeepExactSubmittedValue(_ value: FeedbackHubValue) async throws {
    let transport = HubTestTransport()
    let kind: String
    switch value {
    case .bool: kind = "yes_no"
    case .integer: kind = "rating"
    case .string: kind = "text"
    }
    let served = Self.promptJSON.replacingOccurrences(of: "\"text\"", with: "\"" + kind + "\"")
    await transport.prepare([
      (201, hubIdentityJSON()), (200, served), (200, #"{"answered":true}"#),
      (200, #"{"answered":true}"#),
    ])
    let (client, root, _) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    _ = try await client.nextPrompt()
    // Replaying the original text lets the server apply the same normalization.
    for _ in 0..<2 {
      try await client.enqueue(.promptAnswer, target: Self.promptID, value: value)
      try await client.replay()
    }
    let requests = await transport.requests
    #expect(
      requests.map { $0.url!.path } == [
        "/identity", "/prompts/next", "/prompts/\(Self.promptID)/answer",
        "/prompts/\(Self.promptID)/answer",
      ])
    #expect(requests[1].httpMethod == "GET")
    #expect(
      URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems == [
        URLQueryItem(name: "app", value: "com.example.test")
      ])
    for request in requests.suffix(2) {
      #expect(request.httpMethod == "POST")
      #expect(request.value(forHTTPHeaderField: "x-feedback-secret") == "project-secret")
      #expect(request.value(forHTTPHeaderField: "x-reporter-token") != nil)
      let body = try JSONDecoder().decode([String: FeedbackHubValue].self, from: request.httpBody!)
      #expect(body == ["app": .string("com.example.test"), "value": value])
    }
  }

  @Test func dismissalUsesServedImpressionAndConflictDoesNotReplaceAnswer() async throws {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON()), (200, Self.promptJSON), (200, #"{"dismissed":true}"#),
      (409, #"{"error":"conflict"}"#),
    ])
    let (client, root, _) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    await model.refreshPrompt()
    let served = try #require(model.prompt)
    await model.respond(served, value: nil, dismiss: true)
    let request = try #require(await transport.requests.last)
    let body = try JSONDecoder().decode([String: FeedbackHubValue].self, from: request.httpBody!)
    #expect(
      body == ["app": .string("com.example.test"), "impressionId": .string(Self.impressionID)])
    #expect(model.prompt == nil)
    try await client.enqueue(.promptAnswer, target: Self.promptID, value: .string("different"))
    try await client.replay()
    try await client.replay()
    let queue = try FeedbackOpsQueue(
      url: root.appendingPathComponent("ops.json"), reporterId: "reporter")
    #expect(queue.operations.isEmpty)
    #expect(await transport.requests.count == 4)
  }

  @Test(arguments: [429, 503])
  func transientAnswerErrorsPersistBackoffAndBlockNewImpressions(_ status: Int) async throws {
    let transport = HubTestTransport()
    await transport.prepare([
      (201, hubIdentityJSON()),
      (status, status == 429 ? #"{"error":"hourly-quota"}"# : "Prompt service unavailable"),
    ])
    let (client, root, _) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    try await client.enqueue(.promptAnswer, target: Self.promptID, value: .bool(false))
    try await client.replay()
    try await client.replay()
    #expect(try await client.nextPrompt().isEmpty)
    let queue = try FeedbackOpsQueue(
      url: root.appendingPathComponent("ops.json"), reporterId: "reporter")
    let item = try #require(queue.operations.first)
    #expect(item.attempts == 1)
    #expect(item.nextAttemptAt > Date(timeIntervalSince1970: 2_000_000_000))
    #expect(item.desiredState == .bool(false))
    #expect(await transport.requests.count == 2)
  }

  @Test func resetRejectsLateReservedPrompt() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, _) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    _ = try await client.identity()
    let model = FeedbackHubModel(client: client, config: await client.config)
    await transport.prepare([(200, Self.promptJSON)], suspend: true)
    let task = Task { await model.refreshPrompt() }
    while await transport.requests.count < 2 { await Task.yield() }
    try await client.reset()
    await transport.resume()
    await task.value
    #expect(model.prompt == nil)
    #expect(!model.active)
  }

  @Test func revokedPromptRequestResetsIdentityAndQueue() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (401, "Unauthorized")])
    let (client, root, _) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.prompts])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let model = FeedbackHubModel(client: client, config: await client.config)
    let original = await client.generation
    await model.refreshPrompt()
    #expect(await client.generation != original)
    #expect(model.prompt == nil)
    #expect(!model.active)
  }
}
