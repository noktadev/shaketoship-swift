import Foundation

struct FeedbackConversationSnapshot: Codable, Sendable, Equatable {
  struct Message: Codable, Sendable, Equatable {
    let id: String
    let role: String
    let text: String
    let sessionId: String?
    let replyTo: String?
    var author: String? = nil
  }
  let id: String
  var messages: [Message]
  let kind: String
  let summary: String
  let complete: Bool
  let pending: Bool
  var revision: Int? = nil
  var replyMode: String? = nil
}

/// Stable ordered messages survive upload and network retries. Private hub storage
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
  // Optional fields preserve drafts saved by SDK 3.0. The existing pending slot
  // remains the head; only that message may enter the network at a time.
  var queued: [Pending]?
  var revision: Int?

  var pendingMessages: [Pending] { (pending.map { [$0] } ?? []) + (queued ?? []) }
  var reservedMessageCount: Int {
    (snapshot?.messages.count ?? 0) + pendingMessages.reduce(0) { count, message in
      count + ((snapshot?.messages.contains { $0.id.caseInsensitiveCompare(message.id) == .orderedSame }) == true ? 1 : 2)
    }
  }
}

extension FeedbackHubClient {
  func loadConversation() throws -> FeedbackConversationRecord {
    // ownedSessions performs the same active/identity gate as all private reads.
    _ = try ownedSessions()
    if let record = try storage.read(FeedbackConversationRecord.self, file: "conversation.json"),
      record.generation == localGeneration {
      guard UUID(uuidString: record.id) != nil,
        record.pendingMessages.count <= 20,
        record.pendingMessages.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.text.utf16.count <= FeedbackConversationRecord.maxTextLength }),
        Set(record.pendingMessages.map(\.id)).count == record.pendingMessages.count,
        record.pending != nil || (record.queued ?? []).isEmpty else { throw FeedbackHubError.storage }
      return record
    }
    let created = FeedbackConversationRecord(generation: localGeneration, id: UUID().uuidString.lowercased())
    try storage.write(created, file: "conversation.json")
    return created
  }
  func saveConversation(_ record: FeedbackConversationRecord) throws {
    _ = try ownedSessions()
    guard record.generation == localGeneration else { throw FeedbackHubError.identityChanged }
    try storage.write(record, file: "conversation.json")
  }
  /// Actor-isolated read/modify/write keeps admission and a delayed server reply
  /// from replacing each other's changes to the same local conversation.
  func enqueueConversation(_ source: FeedbackConversationRecord, message: FeedbackConversationRecord.Pending) throws -> FeedbackConversationRecord {
    var latest = try loadConversation()
    guard source.generation == localGeneration, latest.id == source.id else { throw FeedbackHubError.identityChanged }
    guard UUID(uuidString: message.id) != nil else { throw FeedbackHubError.invalidResponse }
    if let existing = latest.pendingMessages.first(where: { $0.id == message.id }) {
      guard existing.text == message.text, existing.hasMedia == message.hasMedia else { throw FeedbackHubError.invalidResponse }
      return latest
    }
    guard latest.reservedMessageCount < 39, latest.pendingMessages.count < 20 else {
      throw FeedbackHubError.invalidResponse
    }
    if latest.pending == nil { latest.pending = message }
    else { latest.queued = (latest.queued ?? []) + [message] }
    latest.revision = (latest.revision ?? 0) + 1
    try saveConversation(latest)
    return latest
  }

  func updateConversation(_ source: FeedbackConversationRecord, pending: FeedbackConversationRecord.Pending,
    snapshot: FeedbackConversationSnapshot? = nil, completed: Bool = false) throws -> FeedbackConversationRecord {
    var latest = try loadConversation()
    guard source.generation == localGeneration, latest.id == source.id,
      latest.pending?.id == pending.id else { throw FeedbackHubError.identityChanged }
    if let snapshot {
      guard snapshot.id == latest.id else { throw FeedbackHubError.invalidResponse }
      if (snapshot.revision ?? 0) >= (latest.snapshot?.revision ?? 0) { latest.snapshot = snapshot }
    }
    if completed {
      guard snapshot?.pending == false else { throw FeedbackHubError.invalidResponse }
      var queue = latest.queued ?? []
      latest.pending = queue.isEmpty ? nil : queue.removeFirst()
      latest.queued = queue.isEmpty ? nil : queue
    } else { latest.pending = pending }
    latest.revision = (latest.revision ?? 0) + 1
    try saveConversation(latest)
    return latest
  }
  /// Refresh only the server snapshot. Local admission and the current draft remain independent.
  func refreshConversation(_ source: FeedbackConversationRecord) async throws -> FeedbackConversationRecord {
    guard source.generation == localGeneration else { throw FeedbackHubError.identityChanged }
    let snapshot = try await decode(FeedbackConversationSnapshot.self, path: "v2/conversations",
      query: [URLQueryItem(name: "id", value: source.id)])
    try Task.checkCancellation()
    return try mergeConversationSnapshot(source, snapshot: snapshot)
  }

  func mergeConversationSnapshot(_ source: FeedbackConversationRecord,
    snapshot: FeedbackConversationSnapshot) throws -> FeedbackConversationRecord {
    var latest = try loadConversation()
    guard source.generation == localGeneration, latest.id == source.id else { throw FeedbackHubError.identityChanged }
    guard snapshot.id == latest.id, snapshot.messages.count <= 40,
      snapshot.messages.allSatisfy({ ["user", "assistant"].contains($0.role) && $0.text.utf16.count <= FeedbackConversationRecord.maxTextLength })
      else { throw FeedbackHubError.invalidResponse }
    // Older servers do not send revisions. POST remains authoritative for those servers.
    guard let revision = snapshot.revision, revision >= 0,
      revision > (latest.snapshot?.revision ?? -1) else { return latest }
    latest.snapshot = snapshot
    latest.revision = (latest.revision ?? 0) + 1
    try saveConversation(latest)
    return latest
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
