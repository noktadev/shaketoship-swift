import Foundation

/// Synchronous atomic transactions, owned by the hub actor. Never use the capture outbox for API mutations.
struct FeedbackOpsQueue {
  enum Operation: String, Codable, Sendable { case vote, promptAnswer, promptDismiss }
  struct Item: Codable, Sendable, Equatable {
    let seq: Int64
    let reporterId: String
    let op: Operation
    let targetId: String
    let desiredState: FeedbackHubValue
    let createdAt: Date
    var attempts: Int = 0
    var nextAttemptAt: Date = .distantPast
  }
  private struct State: Codable {
    let reporterId: String
    var sequence: Int64 = 0
    var operations: [Item] = []
  }
  private let url: URL
  private var state: State
  var operations: [Item] { state.operations }
  init(url: URL, reporterId: String) throws {
    self.url = url
    if FileManager.default.fileExists(atPath: url.path) {
      let stored = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
      state = stored.reporterId == reporterId ? stored : State(reporterId: reporterId)
    } else {
      state = State(reporterId: reporterId)
    }
  }
  @discardableResult
  mutating func enqueue(op: Operation, targetId: String, desiredState: FeedbackHubValue, now: Date)
    throws -> Item
  {
    if op != .vote,
      let existing = operations.first(where: { $0.op == op && $0.targetId == targetId })
    {
      guard existing.desiredState == desiredState else { throw FeedbackHubError.conflict }
      return existing
    }
    guard state.sequence < 9_007_199_254_740_991 else { throw FeedbackHubError.storage }
    var next = state
    next.sequence += 1
    let item = Item(
      seq: next.sequence, reporterId: state.reporterId, op: op,
      targetId: targetId, desiredState: desiredState, createdAt: now)
    next.operations.removeAll { $0.op == op && $0.targetId == targetId }
    next.operations.append(item)
    try commit(next)
    return item
  }
  mutating func remove(seq: Int64) throws {
    var next = state
    next.operations.removeAll { $0.seq == seq }
    try commit(next)
  }
  mutating func prune(now: Date) throws {
    var next = state
    next.operations.removeAll { now.timeIntervalSince($0.createdAt) > 7 * 86400 }
    try commit(next)
  }
  mutating func postpone(_ item: Item, now: Date, retryAfter: TimeInterval?) throws {
    var next = state
    if let i = next.operations.firstIndex(where: { $0.seq == item.seq }) {
      next.operations[i].attempts += 1
      // At most five requests per replay cycle; a later foreground may retry after the delay.
      let delay = max(
        retryAfter ?? 0, min(3600, pow(2, Double(min(next.operations[i].attempts, 10))) * 5))
      next.operations[i].nextAttemptAt = now.addingTimeInterval(delay)
    }
    try commit(next)
  }
  private mutating func commit(_ next: State) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var directory = url.deletingLastPathComponent()
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    try JSONEncoder().encode(next).write(
      to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    state = next
  }
}
