import Testing

@testable import ShakeToShip

/// Sendable collector: the work closures are `@Sendable` and run off the
/// enqueuing context, so the recorder must be an actor.
private actor Recorder {
  private(set) var items: [Int] = []
  func append(_ value: Int) { items.append(value) }
}

@MainActor
@Suite struct FeedbackSerialQueueTests {
  /// A slow first job must still complete before a fast second one: ordered
  /// awaits are what stop a late Live Activity update landing after `end`.
  @Test func runsWorkInEnqueueOrderDespiteUnevenDurations() async {
    let queue = FeedbackSerialQueue()
    let recorder = Recorder()

    queue.enqueue {
      try? await Task.sleep(nanoseconds: 30_000_000)
      await recorder.append(1)
    }
    queue.enqueue { await recorder.append(2) }
    queue.enqueue {
      try? await Task.sleep(nanoseconds: 10_000_000)
      await recorder.append(3)
    }
    await queue.drain()

    #expect(await recorder.items == [1, 2, 3])
  }

  @Test func drainOnEmptyQueueReturns() async {
    let queue = FeedbackSerialQueue()
    await queue.drain()
  }
}
