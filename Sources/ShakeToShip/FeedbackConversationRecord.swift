import Foundation

struct FeedbackConversationSnapshot: Codable, Sendable, Equatable {
  struct Message: Codable, Sendable, Equatable {
    let id: String
    let role: String
    let text: String
    let sessionId: String?
    let replyTo: String?
  }
  let id: String
  var messages: [Message]
  let kind: String
  let summary: String
  let complete: Bool
  let pending: Bool
}

/// One stable pending message survives upload and network retries. Private hub storage
/// and the reporter generation own its lifetime; there is no second upload queue.
struct FeedbackConversationRecord: Codable, Sendable, Equatable {
  static let pendingMarker = ".conversation-pending"
  static let maxTextLength = 4000
  struct Pending: Codable, Sendable, Equatable {
    let id: String
    let text: String
    let hasMedia: Bool
    var sessionID: String?
    var uploaded = false
  }
  let generation: UUID
  let id: String
  var snapshot: FeedbackConversationSnapshot?
  var pending: Pending?
}

extension FeedbackHubClient {
  func loadConversation() throws -> FeedbackConversationRecord {
    // ownedSessions performs the same active/identity gate as all private reads.
    _ = try ownedSessions()
    if let record = try storage.read(FeedbackConversationRecord.self, file: "conversation.json"),
      record.generation == localGeneration {
      guard UUID(uuidString: record.id) != nil,
        record.pending.map({ UUID(uuidString: $0.id) != nil }) ?? true else { throw FeedbackHubError.storage }
      return record
    }
    return FeedbackConversationRecord(generation: localGeneration, id: UUID().uuidString.lowercased())
  }
  func saveConversation(_ record: FeedbackConversationRecord) throws {
    _ = try ownedSessions()
    guard record.generation == localGeneration else { throw FeedbackHubError.identityChanged }
    try storage.write(record, file: "conversation.json")
  }
  func conversationTurn(_ record: FeedbackConversationRecord) async throws -> FeedbackConversationSnapshot {
    guard record.generation == localGeneration, let pending = record.pending else {
      throw FeedbackHubError.identityChanged
    }
    var fields: [String: FeedbackHubValue] = [
      "conversationId": .string(record.id), "messageId": .string(pending.id.lowercased()), "text": .string(pending.text),
    ]
    if let id = pending.sessionID { fields["sessionId"] = .string(id) }
    let snapshot = try await decode(FeedbackConversationSnapshot.self, path: "v2/conversations", method: "POST", fields: fields)
    guard record.generation == localGeneration, snapshot.id == record.id,
      snapshot.messages.count <= 40,
      snapshot.messages.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.text.utf16.count <= FeedbackConversationRecord.maxTextLength }),
      snapshot.messages.contains(where: { $0.id == pending.id.lowercased() && $0.role == "user" }) else {
      throw FeedbackHubError.invalidResponse
    }
    return snapshot
  }
}
