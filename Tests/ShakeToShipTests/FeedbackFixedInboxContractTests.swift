import Foundation
import Testing

@testable import ShakeToShip

struct FeedbackFixedInboxContractTests {
  static let response = #"{"messages":[{"id":"c0000000-0000-4000-8000-000000000001","kind":"fixed","ideaId":null,"createdAt":"2026-09-23T00:00:00Z","payload":{"title":"Your report is fixed"}}]}"#

  @Test @MainActor func genericOrdinaryReportNoticeLoadsAndAcknowledgesWithReporterToken() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport, hub: [.inbox])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    await transport.prepare([(201, hubIdentityJSON()), (200, Self.response), (200, "{}")])
    let model = FeedbackHubModel(client: client, config: await client.config)
    await model.refreshInbox()
    let message = try #require(model.inbox.first)
    #expect(message.kind == "fixed")
    #expect(message.ideaId == nil)
    #expect(message.payload.title == "Your report is fixed")
    #expect(message.payload.text == nil)
    await model.acknowledge(message)
    #expect(model.inbox.isEmpty)
    let requests = await transport.requests
    #expect(requests.map { $0.url!.path } == ["/identity", "/v2/inbox", "/v2/inbox/ack"])
    for request in requests.suffix(2) {
      #expect(request.value(forHTTPHeaderField: "x-feedback-secret") == "project-secret")
      #expect(request.value(forHTTPHeaderField: "x-reporter-token") != nil)
      #expect(!(request.url?.absoluteString.contains("userRef") ?? true))
    }
    let body = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
    #expect(Set(body.keys) == ["app", "messageIds"])
    #expect(body["messageIds"] as? [String] == [message.id])
  }

  @Test @MainActor func lateInboxAfterResetCannotRestoreOldNotice() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport, hub: [.inbox])
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    await transport.prepare([(201, hubIdentityJSON())])
    _ = try await client.identity()
    let model = FeedbackHubModel(client: client, config: await client.config)
    await transport.prepare([(200, Self.response)], suspend: true)
    let pending = Task { await model.refreshInbox() }
    while await transport.requests.count < 2 { await Task.yield() }
    try await client.reset()
    await transport.resume()
    await pending.value
    #expect(model.inbox.isEmpty)
    #expect(!model.active)
    #expect(await transport.requests.count == 2)
  }
}
