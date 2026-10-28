import Foundation

/// A deliberately small message vocabulary. Actions never execute during decoding
/// or polling. Only authenticated team messages can supply these controls.
struct FeedbackConversationAction: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case link(URL)
    case reply(String)
    case recordScreen
  }
  let id: String
  let label: String
  let kind: Kind
}

/// Standalone Markdown links keep the existing text protocol readable in Discord,
/// the dashboard, and older SDKs. Unsupported or malformed links remain plain text.
struct FeedbackConversationContent: Equatable, Sendable {
  let text: String
  let actions: [FeedbackConversationAction]

  init(text: String, allowsActions: Bool) {
    guard allowsActions,
      let pattern = try? NSRegularExpression(pattern: #"^\[([^\[\]\r\n]{1,80})\]\(([^\s]+)\)$"#)
    else { self.text = text; actions = []; return }
    var body: [String] = []
    var parsed: [FeedbackConversationAction] = []
    var fence: String?
    for (index, line) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).enumerated() {
      let candidate = line.trimmingCharacters(in: .whitespaces)
      if let marker = fence {
        if candidate.count >= marker.count && candidate.allSatisfy({ $0 == marker.first! }) { fence = nil }
        body.append(line)
        continue
      }
      if line.hasPrefix("    ") || line.hasPrefix("\t") {
        body.append(line)
        continue
      }
      if candidate.hasPrefix("```") || candidate.hasPrefix("~~~") {
        fence = String(candidate.prefix(while: { $0 == candidate.first! }))
        body.append(line)
        continue
      }
      guard parsed.count < 3,
        let match = pattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
        let labelRange = Range(match.range(at: 1), in: candidate),
        let targetRange = Range(match.range(at: 2), in: candidate),
        let kind = Self.kind(String(candidate[targetRange])),
        !candidate[labelRange].trimmingCharacters(in: .whitespaces).isEmpty
      else { body.append(line); continue }
      parsed.append(.init(id: String(index), label: String(candidate[labelRange]).trimmingCharacters(in: .whitespaces), kind: kind))
    }
    self.text = parsed.isEmpty ? text : body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    actions = parsed
  }

  private static func kind(_ target: String) -> FeedbackConversationAction.Kind? {
    guard target.utf16.count <= 2048,
      let components = URLComponents(string: target),
      components.user == nil, components.password == nil,
      let url = components.url else { return nil }
    if components.scheme?.lowercased() == "https",
      let host = components.host, !host.isEmpty {
      return .link(url)
    }
    guard components.scheme?.lowercased() == "shaketoship", components.port == nil,
      components.path.isEmpty, components.fragment == nil else { return nil }
    if components.host?.lowercased() == "record", components.query == nil { return .recordScreen }
    if components.host?.lowercased() == "reply", let items = components.queryItems,
      items.count == 1, items[0].name == "text", let text = items[0].value,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf16.count <= 1000 {
      return .reply(text)
    }
    return nil
  }
}
