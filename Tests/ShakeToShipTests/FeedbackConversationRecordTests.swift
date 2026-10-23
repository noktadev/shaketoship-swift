import Foundation
import Testing
@testable import ShakeToShip

struct FeedbackConversationRecordTests {
  @Test func pendingMessageSurvivesFailureAndRetriesWithSameIdentity() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    var record = try await client.loadConversation()
    let id = UUID().uuidString.lowercased()
    record.pending = .init(id: id, text: "Please add offline practice", hasMedia: false)
    try await client.saveConversation(record)
    #expect(try await client.loadConversation() == record)
    await transport.prepare([(200, hubIdentityJSON()), (503, "Unavailable")])
    do { _ = try await client.conversationTurn(record); Issue.record("Expected network failure") }
    catch { }
    #expect(try await client.loadConversation().pending?.id == id)
    let snapshot = FeedbackConversationSnapshot(id: record.id, messages: [
      .init(id: id, role: "user", text: record.pending!.text, sessionId: nil, replyTo: nil),
      .init(id: id + "-reply", role: "assistant", text: "Thanks.", sessionId: nil, replyTo: id),
    ], kind: "feature_request", summary: "Offline practice", complete: true, pending: false)
    await transport.prepare([(200, String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))])
    #expect(try await client.conversationTurn(record) == snapshot)
    let requests = await transport.requests.filter { $0.url?.path == "/v2/conversations" }
    #expect(requests.count == 2)
    #expect(requests[0].httpBody == requests[1].httpBody)
    #expect(requests[0].value(forHTTPHeaderField: "x-reporter-token") != nil)
  }
  @Test func identityResetErasesPrivateTranscriptAndRejectsLateSave() async throws {
    let transport = HubTestTransport()
    let (client, root, storage) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let record = try await client.loadConversation()
    try await client.saveConversation(record)
    try await client.reset()
    #expect(try storage.read(FeedbackConversationRecord.self, file: "conversation.json") == nil)
    do { try await client.saveConversation(record); Issue.record("Stale save must fail") }
    catch { }
    #expect(try await client.loadConversation().id != record.id)
  }
}

extension FeedbackConversationRecordTests {
  @Test func resetErasesSubmittedRecordingWithPendingMarker() async throws {
    let transport = HubTestTransport()
    let (client, root, storage) = try FeedbackHubClientTests().fixture(transport: transport)
    let directory = FeedbackReportDraftStore.defaultOutboxRoot.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: directory) }
    await client.setActive(true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try await client.bindCapture(in: directory, purpose: .feedback)
    try Data().write(to: directory.appendingPathComponent(FeedbackConversationRecord.pendingMarker))
    try Data("private capture".utf8).write(to: directory.appendingPathComponent("recording.mov"))
    try storage.clearPrivateData()
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }
}
