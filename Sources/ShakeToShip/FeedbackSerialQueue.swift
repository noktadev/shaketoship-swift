import Foundation

/// Serializes fire-and-forget async work in enqueue order by chaining each new
/// task onto the previous one's completion.
///
/// Live Activity update/end are unstructured Tasks: without a chain a late
/// `update` can land after `end` (resurrecting a finished activity) and two
/// in-flight updates can complete out of order (screen count regressing).
/// MainActor-isolated so `enqueue` is synchronous from the MainActor call
/// sites - call order IS run order, with no interleaving suspension.
///
/// Platform-neutral (no ActivityKit) so the ordering guarantee is unit tested.
@MainActor
final class FeedbackSerialQueue {
  private var tail: Task<Void, Never>?

  init() {}

  func enqueue(_ work: @escaping @Sendable () async -> Void) {
    let prior = tail
    tail = Task {
      await prior?.value
      await work()
    }
  }

  /// Awaits the currently queued work. Test/teardown helper.
  func drain() async {
    await tail?.value
  }
}
