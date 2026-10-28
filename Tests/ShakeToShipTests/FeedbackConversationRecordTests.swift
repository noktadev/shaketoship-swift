import Foundation
import Testing
@testable import ShakeToShip

struct FeedbackConversationRecordTests {
  @Test func reservedContextRecognizesAnAcceptedLegacyUppercaseID() {
    var record = FeedbackConversationRecord(generation: UUID(), id: UUID().uuidString.lowercased())
    let id = UUID().uuidString.uppercased()
    record.pending = .init(id: id, text: "More detail", hasMedia: false)
    record.snapshot = .init(id: record.id, messages: [
      .init(id: id.lowercased(), role: "user", text: "More detail", sessionId: nil, replyTo: nil),
    ], kind: "feedback", summary: "", complete: false, pending: true)
    #expect(record.reservedMessageCount == 2)
  }

  @Test func delayedReplyPreservesMessagesQueuedFromAnOlderSnapshot() async throws {
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: HubTestTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let initial = try await client.loadConversation()
    let first = FeedbackConversationRecord.Pending(id: UUID().uuidString.lowercased(), text: "First detail", hasMedia: false)
    let second = FeedbackConversationRecord.Pending(id: UUID().uuidString.lowercased(), text: "More detail", hasMedia: true)
    let inFlight = try await client.enqueueConversation(initial, message: first)
    _ = try await client.enqueueConversation(inFlight, message: second)
    let duplicate = try await client.enqueueConversation(inFlight, message: second)
    #expect(duplicate.pendingMessages.map(\.id) == [first.id, second.id])
    #expect(try await client.loadConversation().pendingMessages.map(\.text) == [first.text, second.text])
    let snapshot = FeedbackConversationSnapshot(id: initial.id, messages: [
      .init(id: first.id, role: "user", text: first.text, sessionId: nil, replyTo: nil),
      .init(id: first.id + "-reply", role: "assistant", text: "Tell me more.", sessionId: nil, replyTo: first.id),
    ], kind: "feedback", summary: "Details", complete: false, pending: false)
    // This response belongs to the request started before the second admission.
    let advanced = try await client.updateConversation(inFlight, pending: first, snapshot: snapshot, completed: true)
    #expect(advanced.pending?.id == second.id)
    #expect(advanced.pending?.hasMedia == true)
    #expect(advanced.queued == nil)
    #expect(advanced.snapshot == snapshot)
    #expect(try await client.loadConversation() == advanced)
    do {
      _ = try await client.updateConversation(inFlight, pending: first, snapshot: snapshot, completed: true)
      Issue.record("A late acknowledgement must not remove the next message")
    } catch { }
    #expect(try await client.loadConversation() == advanced)
  }

  @Test func legacyPendingRecordLoadsAndIdentityResetRejectsItsQueue() async throws {
    let (client, root, storage) = try FeedbackHubClientTests().fixture(transport: HubTestTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    var old = try await client.loadConversation()
    old.pending = .init(id: UUID().uuidString.lowercased(), text: "Saved by 3.0", hasMedia: false)
    try storage.write(old, file: "conversation.json") // Optional queue/revision keys are omitted.
    let restored = try await client.loadConversation()
    #expect(restored.queued == nil)
    #expect(restored.pendingMessages.count == 1)
    try await client.reset()
    do {
      _ = try await client.enqueueConversation(restored, message: .init(id: UUID().uuidString.lowercased(), text: "Old identity", hasMedia: false))
      Issue.record("Reset must reject the old conversation")
    } catch { }
    #expect(try await client.loadConversation().pendingMessages.isEmpty)
  }

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
    await transport.prepare([(200, hubIdentityJSON()), (404, "Not found"), (503, "Unavailable")])
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
    // JSON object key order is unspecified; retries must preserve every field.
    let firstBody = try #require(requests[0].httpBody)
    let retryBody = try #require(requests[1].httpBody)
    let firstPayload = try #require(JSONSerialization.jsonObject(with: firstBody) as? NSDictionary)
    let retryPayload = try #require(JSONSerialization.jsonObject(with: retryBody) as? NSDictionary)
    #expect(firstPayload == retryPayload)
    #expect(firstPayload["messageId"] as? String == id)
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

extension FeedbackConversationRecordTests {
  @Test func incomingTeamReplyPreservesQueuedDraftsAndRejectsStaleServerSnapshots() async throws {
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: HubTestTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let initial = try await client.loadConversation()
    let first = FeedbackConversationRecord.Pending(id: UUID().uuidString.lowercased(), text: "First", hasMedia: false)
    let second = FeedbackConversationRecord.Pending(id: UUID().uuidString.lowercased(), text: "Second", hasMedia: false)
    let sending = try await client.enqueueConversation(initial, message: first)
    _ = try await client.enqueueConversation(sending, message: second)
    let human = FeedbackConversationSnapshot(id: initial.id, messages: [
      .init(id: first.id, role: "user", text: first.text, sessionId: nil, replyTo: nil),
      .init(id: "discord-1551650946004553841", role: "assistant", text: "I can help", sessionId: nil, replyTo: first.id, author: "team"),
    ], kind: "feedback", summary: "", complete: false, pending: false, revision: 3, replyMode: "human")
    let refreshed = try await client.mergeConversationSnapshot(sending, snapshot: human)
    #expect(refreshed.pendingMessages.map(\.id) == [first.id, second.id])
    var old = human
    old.revision = 2
    old.messages.removeLast()
    #expect(try await client.mergeConversationSnapshot(sending, snapshot: old).snapshot == human)
    let delivered = try await client.updateConversation(sending, pending: first, snapshot: old, completed: true)
    #expect(delivered.snapshot == human)
    #expect(delivered.pending?.id == second.id)
    try await client.reset()
    do {
      _ = try await client.mergeConversationSnapshot(sending, snapshot: human)
      Issue.record("A late refresh must not restore an erased transcript")
    } catch { }
  }
}

extension FeedbackConversationRecordTests {
  @Test func asyncReceiptAdvancesQueueBeforeAssistantReply() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let initial = try await client.loadConversation()
    let first = FeedbackConversationRecord.Pending(id: UUID().uuidString.lowercased(), text: "First", hasMedia: false)
    let second = FeedbackConversationRecord.Pending(id: UUID().uuidString.lowercased(), text: "Second", hasMedia: false)
    let record = try await client.enqueueConversation(initial, message: first)
    _ = try await client.enqueueConversation(record, message: second)
    let snapshot = FeedbackConversationSnapshot(id: record.id, messages: [
      .init(id: first.id, role: "user", text: first.text, sessionId: nil, replyTo: nil)
    ], kind: "feedback", summary: "", complete: false, pending: true)
    let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    await transport.prepare([(200, hubIdentityJSON()), (200, #"{"asyncAdmission":true}"#),
      (202, "{\"accepted\":true,\"sequence\":1,\"conversation\":\(json)}")])
    let receipt = try await client.conversationTurn(record)
    #expect(receipt.pending)
    #expect(receipt.acceptedMessageID == first.id)
    let advanced = try await client.updateConversation(record, pending: first, snapshot: receipt, completed: true)
    #expect(advanced.pending?.id == second.id)
    #expect(advanced.snapshot?.messages.count == 1)
  }

  @Test func capabilityFailureRetainsQueueWithoutSilentV2Downgrade() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let initial = try await client.loadConversation()
    let message = FeedbackConversationRecord.Pending(id: UUID().uuidString.lowercased(), text: "Keep me", hasMedia: false)
    let record = try await client.enqueueConversation(initial, message: message)
    await transport.prepare([(200, hubIdentityJSON()), (503, "Unavailable")])
    do { _ = try await client.conversationTurn(record); Issue.record("Expected failure") } catch { }
    #expect(try await client.loadConversation().pending?.id == message.id)
    #expect(await transport.requests.allSatisfy { $0.url?.path != "/v2/conversations" })
  }
}
