import Foundation
import Testing

@testable import ShakeToShip

struct FeedbackHubTests {
  @Test func hubRequiresBothGates() {
    let disabled = ShakeToShipConfig(
      app: "test", collectorURL: URL(string: "https://test.invalid")!, secret: "secret")
    #expect(disabled.hub.isEmpty)
    #expect(!FeedbackGate.shouldAttachHub(config: disabled, recorderActive: true))
    let enabled = ShakeToShipConfig(
      app: "test", collectorURL: disabled.collectorURL, secret: "secret", hub: [.ideas])
    #expect(!FeedbackGate.shouldAttachHub(config: enabled, recorderActive: false))
    #expect(FeedbackGate.shouldAttachHub(config: enabled, recorderActive: true))
    let empty = ShakeToShipConfig(
      app: "test", collectorURL: disabled.collectorURL, secret: "secret", capabilities: [],
      hub: [.ideas])
    #expect(!FeedbackGate.shouldAttachHub(config: empty, recorderActive: true))
    #expect(enabled.with(onFunnelEvent: nil, onOptOut: nil).hub == [.ideas])
  }

  @Test func queueSurvivesRestartAndKeepsSequenceAfterAcknowledgement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = root.appendingPathComponent("ops.json")
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = try FeedbackOpsQueue(url: url, reporterId: "reporter")
    let first = try queue.enqueue(
      op: .vote, targetId: "idea", desiredState: .bool(true), now: Date())
    _ = try queue.enqueue(op: .vote, targetId: "idea", desiredState: .bool(false), now: Date())
    queue = try FeedbackOpsQueue(url: url, reporterId: "reporter")
    #expect(queue.operations.count == 1)
    #expect(queue.operations[0].desiredState == .bool(false))
    #expect(queue.operations[0].seq > first.seq)
    let seq = queue.operations[0].seq
    try queue.remove(seq: seq)
    queue = try FeedbackOpsQueue(url: url, reporterId: "reporter")
    let next = try queue.enqueue(
      op: .vote, targetId: "other", desiredState: .bool(true), now: Date())
    #expect(next.seq > seq)
    let foreign = try FeedbackOpsQueue(url: url, reporterId: "other-reporter")
    #expect(foreign.operations.isEmpty)
  }

  @Test func queueExpiresAndPromptAnswersAreImmutable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = root.appendingPathComponent("ops.json")
    defer { try? FileManager.default.removeItem(at: root) }
    var queue = try FeedbackOpsQueue(url: url, reporterId: "r")
    let now = Date()
    _ = try queue.enqueue(
      op: .vote, targetId: "old", desiredState: .bool(true), now: now.addingTimeInterval(-8 * 86400)
    )
    _ = try queue.enqueue(
      op: .promptAnswer, targetId: "p", desiredState: .string("first"), now: now)
    #expect(throws: FeedbackHubError.self) {
      try queue.enqueue(
        op: .promptAnswer, targetId: "p", desiredState: .string("changed"), now: now)
    }
    try queue.prune(now: now)
    #expect(queue.operations.count == 1)
  }
}
