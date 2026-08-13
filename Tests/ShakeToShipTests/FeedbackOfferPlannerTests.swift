import Foundation
import Testing

@testable import ShakeToShip

/// #472/#491: the interrupted-session resend offer's "present vs re-arm vs drop"
/// decision, extracted out of the untestable SwiftUI modifier into
/// `FeedbackOfferPlanner`. These are the regression net #491's race fixes
/// (coalesced scans, serialized sweep-vs-offer) should extend rather than
/// re-deriving inline. Fixture style mirrors `FeedbackInterruptedSessionTests`
/// (temp dirs, real markers) since the planner reads on-disk mtime + pending
/// state for the selected candidate.
@Suite struct FeedbackOfferPlannerTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-planner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// A finalized pending-interrupted dir: recording.mov + events.json +
  /// `.interrupted`, optionally `.confirmed`. `modified` stamps a deterministic
  /// mtime so newest-first selection is not flaky on create order.
  @discardableResult
  private func makeSession(
    _ root: URL, _ id: String,
    mov: Bool = true, interrupted: Bool = true, confirmed: Bool = false,
    modified: Date? = nil
  ) throws -> FeedbackPendingInterrupted {
    let dir = root.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if mov { try Data("video".utf8).write(to: dir.appendingPathComponent("recording.mov")) }
    try Data("{}".utf8).write(to: dir.appendingPathComponent("events.json"))
    if interrupted {
      try Data().write(to: dir.appendingPathComponent(feedbackInterruptedMarker))
    }
    if confirmed {
      try Data().write(to: dir.appendingPathComponent(feedbackConfirmedMarker))
    }
    if let modified {
      try FileManager.default.setAttributes(
        [.modificationDate: modified], ofItemAtPath: dir.path)
    }
    return FeedbackPendingInterrupted(sessionId: id, dir: dir)
  }

  @Test func presentsNewestOfTwoPending() throws {
    let root = try makeRoot()
    let older = try makeSession(root, "old", modified: Date(timeIntervalSince1970: 1_000))
    let newer = try makeSession(root, "new", modified: Date(timeIntervalSince1970: 2_000))
    // Order in the scan list must not matter - selection is by mtime.
    let decision = FeedbackOfferPlanner.decide(
      scanResult: [older, newer], busy: false, presentationPossible: true,
      scanInFlight: false, now: Date())
    #expect(decision == .present(newer))
  }

  @Test func busyReArms() throws {
    let root = try makeRoot()
    let pending = try makeSession(root, "s1")
    let decision = FeedbackOfferPlanner.decide(
      scanResult: [pending], busy: true, presentationPossible: true,
      scanInFlight: false, now: Date())
    #expect(decision == .rearm)
  }

  @Test func presentationImpossibleReArms() throws {
    let root = try makeRoot()
    let pending = try makeSession(root, "s1")
    let decision = FeedbackOfferPlanner.decide(
      scanResult: [pending], busy: false, presentationPossible: false,
      scanInFlight: false, now: Date())
    #expect(decision == .rearm)
  }

  @Test func emptyScanDrops() {
    let decision = FeedbackOfferPlanner.decide(
      scanResult: [], busy: false, presentationPossible: true,
      scanInFlight: false, now: Date())
    #expect(decision == .drop)
  }

  @Test func scanInFlightDrops() throws {
    let root = try makeRoot()
    let pending = try makeSession(root, "s1")
    // A concurrent scan is already running - this invocation must do nothing,
    // even with an otherwise-presentable partial.
    let decision = FeedbackOfferPlanner.decide(
      scanResult: [pending], busy: false, presentationPossible: true,
      scanInFlight: true, now: Date())
    #expect(decision == .drop)
  }

  @Test func diskRevalidationMissDropsWithoutCrash() throws {
    let root = try makeRoot()
    let pending = try makeSession(root, "s1")
    // Simulate the partial being uploaded/discarded between scan and decision:
    // remove its dir so `isStillPendingInterrupted` fails. Must drop, not crash
    // on the vanished dir's mtime lookup.
    try FileManager.default.removeItem(at: pending.dir)
    let decision = FeedbackOfferPlanner.decide(
      scanResult: [pending], busy: false, presentationPossible: true,
      scanInFlight: false, now: Date())
    #expect(decision == .drop)
  }

  @Test func confirmedCandidateDropsAtRevalidation() throws {
    let root = try makeRoot()
    // Marker set says pending, but a `.confirmed` landed before the decision -
    // revalidation must reject it (never re-offer an already-owned session).
    let pending = try makeSession(root, "s1", confirmed: true)
    let decision = FeedbackOfferPlanner.decide(
      scanResult: [pending], busy: false, presentationPossible: true,
      scanInFlight: false, now: Date())
    #expect(decision == .drop)
  }
}
