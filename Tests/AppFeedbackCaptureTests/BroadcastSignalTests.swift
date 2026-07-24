import Foundation
import Testing

@testable import AppFeedbackCapture

/// Exercises the real notify(3) daemon - the same transport the extension and
/// the host app use to talk across the process boundary. Nothing here is
/// stubbed: a post really goes through notifyd and comes back on our queue.
@Suite struct BroadcastSignalTests {
  /// A unique App Group id per test so two tests posting concurrently (or a
  /// second checkout running the suite at the same time) can never observe each
  /// other's notifications.
  private func uniqueSignals() -> BroadcastSignals {
    BroadcastSignals(appGroupIdentifier: "group.test.\(UUID().uuidString).shaketoship")
  }

  /// Spins until `condition` holds or the deadline passes. Darwin notifications
  /// are delivered asynchronously by notifyd, so there is no post-and-assert.
  private func eventually(
    timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
  }

  @Test func namesAreScopedToTheAppGroupSoTwoAppsCannotCrossTalk() {
    let a = BroadcastSignals(appGroupIdentifier: "group.com.example.one.shaketoship")
    let b = BroadcastSignals(appGroupIdentifier: "group.com.example.two.shaketoship")

    #expect(a.started == "group.com.example.one.shaketoship.broadcastStarted")
    #expect(a.stopped == "group.com.example.one.shaketoship.broadcastStopped")
    #expect(a.requestStop == "group.com.example.one.shaketoship.broadcastRequestStop")
    #expect(a.started != b.started)
    #expect(a.stopped != b.stopped)
    #expect(a.requestStop != b.requestStop)
  }

  @Test func anObserverFiresOnARealDarwinPost() async throws {
    let signals = uniqueSignals()
    let fired = Counter()
    let observation = try #require(
      DarwinSignals.observe(signals.started) { fired.bump() })
    defer { observation.cancel() }

    DarwinSignals.post(signals.started)

    #expect(await eventually { fired.value >= 1 })
  }

  @Test func anObserverIgnoresADifferentSignalOnTheSameChannel() async throws {
    let signals = uniqueSignals()
    let started = Counter()
    let stopped = Counter()
    let startObservation = try #require(
      DarwinSignals.observe(signals.started) { started.bump() })
    let stopObservation = try #require(
      DarwinSignals.observe(signals.stopped) { stopped.bump() })
    defer {
      startObservation.cancel()
      stopObservation.cancel()
    }

    DarwinSignals.post(signals.stopped)

    #expect(await eventually { stopped.value >= 1 })
    #expect(started.value == 0)
  }

  @Test func aCancelledObservationStopsReceiving() async throws {
    let signals = uniqueSignals()
    let fired = Counter()
    let observation = try #require(
      DarwinSignals.observe(signals.started) { fired.bump() })

    DarwinSignals.post(signals.started)
    #expect(await eventually { fired.value >= 1 })
    let afterFirst = fired.value

    observation.cancel()
    DarwinSignals.post(signals.started)
    // Give a delivery that should never come time to arrive anyway.
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(fired.value == afterFirst)
  }
}

/// Minimal thread-safe tally - the notify handler runs on its own queue.
final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func bump() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
