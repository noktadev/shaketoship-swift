import Foundation

// Explicit public wire shapes. Private reporter fields cannot enter these models.
struct FeedbackIdea: Codable, Identifiable, Sendable, Equatable {
  let id: String
  let title: String
  let status: String
  var voteCount: Int
  var votedByMe: Bool
  let replyExcerpt: String?
  var body: String?
  var createdAt: String?
  var pinnedReply: Reply?
  var myDetailCount: Int?
  struct Reply: Codable, Sendable, Equatable {
    let text: String
    let updatedAt: String
  }
  var statusLabel: String { status.replacingOccurrences(of: "_", with: " ").capitalized }
}
struct FeedbackIdeaPage: Codable, Sendable {
  var ideas: [FeedbackIdea]
  let nextCursor: String?
}
struct FeedbackSimilarIdeas: Decodable, Sendable {
  let similar: [FeedbackIdea]
  let threshold: Double
  let thresholdEvaluation: String
}
struct FeedbackInbox: Decodable, Sendable { let messages: [FeedbackInboxMessage] }
struct FeedbackInboxMessage: Decodable, Identifiable, Sendable {
  let id: String
  let kind: String
  let ideaId: String?
  let createdAt: String
  let payload: Payload
  struct Payload: Decodable, Sendable {
    let title: String?
    let text: String?
  }
}
struct FeedbackEmailStatus: Decodable, Sendable, Equatable {
  let delivery: String
  let consent: String
  let pendingReplacement: Bool
  let revision: Int64
  var canUnsubscribe: Bool { consent != "none" || pendingReplacement }
  var description: String {
    if delivery == "disabled" { return "Email updates are unavailable." }
    if pendingReplacement {
      return "Your current email remains active while the new address awaits confirmation."
    }
    switch consent {
    case "verified": return "Email updates are on."
    case "pending": return "Email confirmation is pending."
    default: return "Email updates are off."
    }
  }
}
struct FeedbackEmailEnrollment: Decodable, Sendable {
  let accepted: Bool
  let delivery: String
}
struct FeedbackPrompt: Decodable, Sendable, Identifiable {
  let id: String
  let kind: String
  let question: String
  let impressionId: String

  /// Match the server scalar type and JavaScript UTF-16 string length before enqueueing.
  func accepts(_ value: FeedbackHubValue) -> Bool {
    switch (kind, value) {
    case ("yes_no", .bool): return true
    case ("rating", .integer(let rating)): return (1...5).contains(rating)
    case ("text", .string(let text)):
      // JavaScript String.trim whitespace. Keep the original value for replay.
      let nonblank = text.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x9...0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028...0x2029,
          0x202F, 0x205F, 0x3000, 0xFEFF: return false
        default: return true
        }
      }
      return text.utf16.count <= 2000 && nonblank
    default: return false
    }
  }
}
struct FeedbackReporterIdentity: Codable, Sendable, Equatable {
  let reporterId: String
  let reporterToken: String
  // Decoding an expiry is only a renewal hint. The server verifies the signature.
  var expiresAt: Date? {
    let parts = reporterToken.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var raw = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    raw += String(repeating: "=", count: (4 - raw.count % 4) % 4)
    guard let data = Data(base64Encoded: raw),
      let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let exp = fields["exp"] as? Double
    else { return nil }
    return Date(timeIntervalSince1970: exp)
  }
}

enum FeedbackHubValue: Codable, Sendable, Equatable {
  case bool(Bool)
  case integer(Int)
  case string(String)
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let n = try? c.decode(Int.self) {
      self = .integer(n)
    } else {
      self = .string(try c.decode(String.self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .bool(let v): try c.encode(v)
    case .integer(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    }
  }
}

enum FeedbackHubError: Error, Equatable, LocalizedError {
  case inactive, identityChanged, visibilityChanged, authentication, conflict, invalidResponse,
    invalidPromptAnswer,
    storage
  case http(Int, String, TimeInterval?)
  var errorDescription: String? {
    switch self {
    case .inactive: "Feedback is unavailable."
    case .identityChanged: "Your feedback identity changed. Open feedback again."
    case .visibilityChanged: "Ideas changed. Refresh the list."
    case .authentication: "Your feedback identity has expired. Open feedback again."
    case .conflict: "This response is already saved."
    case .invalidResponse: "The service returned an invalid response."
    case .invalidPromptAnswer: "Review your response and try again."
    case .storage: "Feedback could not be saved on this device."
    case .http(let code, _, _):
      code == 404 ? "This item is no longer available." : "Feedback could not connect. Try again."
    }
  }
}

struct FeedbackErrorDTO: Decodable { let error: String }
