import Foundation
import Testing

@testable import ShakeToShip

/// The start-race guard (#453): a start task can complete after the scene has
/// deactivated (ReplayKit is awaited before `isRecording` flips), so the guard
/// tells a completing start whether it must abort because a deactivation landed
/// while it was in flight - and refuses a start requested while the scene is
/// already inactive.
@Suite struct FeedbackStartGuardTests {
  @Test func startWithNoDeactivationDoesNotAbort() throws {
    var guardState = FeedbackStartGuard()
    let started = guardState.begin()
    let token = try #require(started)
    #expect(guardState.shouldAbort(startedEpoch: token) == false)
  }

  @Test func deactivationDuringStartAborts() throws {
    var guardState = FeedbackStartGuard()
    let started = guardState.begin()
    let token = try #require(started)
    guardState.deactivate()
    #expect(guardState.shouldAbort(startedEpoch: token))
  }

  @Test func deactivationBeforeANewerStartDoesNotAbortIt() throws {
    var guardState = FeedbackStartGuard()
    let startedStale = guardState.begin()
    let stale = try #require(startedStale)
    guardState.deactivate()  // aborts `stale` AND blocks new starts
    guardState.activate()  // re-arm after returning to the foreground
    let startedFresh = guardState.begin()  // a brand-new start after
    let fresh = try #require(startedFresh)
    #expect(guardState.shouldAbort(startedEpoch: fresh) == false)
    // The stale start, if it ever completes, still aborts.
    #expect(guardState.shouldAbort(startedEpoch: stale))
  }

  /// Regression for the queued-begin race: a `begin()` requested AFTER a
  /// `deactivate()` (e.g. `resolvePrompt` queued `startRecording` but the scene
  /// backgrounded / `onDisappear`ed before it ran) must be refused - there is no
  /// teardown event left to stop such a capture.
  @Test func beginWhileDeactivatedIsRejected() {
    var guardState = FeedbackStartGuard()
    guardState.deactivate()
    #expect(guardState.begin() == nil)
  }

  @Test func reactivationReenablesBegin() throws {
    var guardState = FeedbackStartGuard()
    #expect(guardState.begin() != nil)
    guardState.deactivate()
    #expect(guardState.begin() == nil)
    guardState.activate()
    let started = guardState.begin()
    let token = try #require(started)
    #expect(guardState.shouldAbort(startedEpoch: token) == false)
  }
}
