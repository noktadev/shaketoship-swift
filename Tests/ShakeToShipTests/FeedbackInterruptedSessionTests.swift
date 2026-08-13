import Foundation
import Testing

@testable import ShakeToShip

/// #472: a recording interrupted by backgrounding is finalized to the outbox and
/// tagged with the `.interrupted` marker so the next foreground can offer to send
/// the partial. These cover the marker write + the pending-scan seam that the
/// modifier reads on `willEnterForeground`.
@Suite struct FeedbackInterruptedSessionTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-int-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// Finalized session dir: recording.mov + events.json. Markers added per flag.
  @discardableResult
  private func makeSession(
    _ root: URL, _ id: String,
    mov: Bool = true, interrupted: Bool, confirmed: Bool = false
  ) throws -> URL {
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
    return dir
  }

  @Test func interruptedFinalizedSessionIsPending() throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", interrupted: true)
    let pending = pendingInterruptedSessions(root: root, fileManager: .default)
    #expect(pending.map(\.sessionId) == ["s1"])
    // Compare resolved paths: contentsOfDirectory returns the /private-prefixed
    // canonical form of a /var tmp dir, so a raw URL equality would spuriously
    // differ on the symlink alone.
    #expect(pending.first?.dir.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath())
  }

  @Test func confirmedSessionIsNotPending() throws {
    let root = try makeRoot()
    try makeSession(root, "s1", interrupted: true, confirmed: true)
    #expect(pendingInterruptedSessions(root: root, fileManager: .default).isEmpty)
  }

  @Test func interruptedWithoutRecordingIsNotPending() throws {
    let root = try makeRoot()
    try makeSession(root, "s1", mov: false, interrupted: true)
    #expect(pendingInterruptedSessions(root: root, fileManager: .default).isEmpty)
  }

  @Test func nonInterruptedSessionIsNotPending() throws {
    let root = try makeRoot()
    try makeSession(root, "s1", interrupted: false)
    #expect(pendingInterruptedSessions(root: root, fileManager: .default).isEmpty)
  }

  @Test func markerWriteLandsOnDisk() throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", interrupted: false)
    #expect(writeFeedbackInterruptedMarker(in: dir))
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(feedbackInterruptedMarker).path))
  }

  /// The interrupted (but unconfirmed) session must NEVER auto-upload: the sweep
  /// gate is `.confirmed`-only, so an `.interrupted` marker changes nothing.
  @Test func interruptedUnconfirmedNeverUploads() async throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", interrupted: true)
    let t = FakeTransport([])  // must never be hit
    let uploader = FeedbackUploader(
      config: ShakeToShipConfig(
        app: "dotself", collectorURL: URL(string: "https://c.example.com")!, secret: "s"),
      transport: t, fileManager: .default, outboxRoot: root)

    let result = await uploader.retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 0))
    #expect(FileManager.default.fileExists(atPath: dir.path))
    #expect(t.requests.isEmpty)
    #expect(t.uploads.isEmpty)
  }

  /// #472 finding 4: the launch sweep must PRESERVE a stale interrupted partial
  /// (it is owned by the foreground resend offer), never purge it - otherwise the
  /// sweep could delete the dir the offer's review sheet is presenting.
  @Test func staleInterruptedDirSurvivesSweep() async throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", interrupted: true)
    // Backdate well past the 1h purge horizon: an ordinary unconfirmed dir would
    // be purged here; an interrupted one must not be.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: dir.path)
    let t = FakeTransport([])  // must never be hit
    let uploader = FeedbackUploader(
      config: ShakeToShipConfig(
        app: "dotself", collectorURL: URL(string: "https://c.example.com")!, secret: "s"),
      transport: t, fileManager: .default, outboxRoot: root)

    let result = await uploader.retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 0))
    #expect(FileManager.default.fileExists(atPath: dir.path))
    #expect(t.requests.isEmpty)
    #expect(t.uploads.isEmpty)
  }

  /// #472 NEW-3: interrupted retention is capped. A partial older than
  /// `interruptedRetention` (an offer the user never answered) is purged so they
  /// cannot accumulate unbounded, even though a fresh one is preserved.
  @Test func interruptedDirPurgedPastRetentionCap() async throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", interrupted: true)
    // 2h old; with a 60s retention cap it is well past the horizon.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: dir.path)
    let t = FakeTransport([])  // must never be hit
    let uploader = FeedbackUploader(
      config: ShakeToShipConfig(
        app: "dotself", collectorURL: URL(string: "https://c.example.com")!, secret: "s"),
      transport: t, fileManager: .default, outboxRoot: root)

    let result = await uploader.retryOutbox(purgeAge: 3600, interruptedRetention: 60)

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 1))
    #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    #expect(t.requests.isEmpty)
    #expect(t.uploads.isEmpty)
  }

  /// A stale interrupted husk WITHOUT a recording has nothing to offer, so it is
  /// not preserved - it falls through to the ordinary stale purge.
  @Test func staleInterruptedHuskWithoutRecordingIsPurged() async throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", mov: false, interrupted: true)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: dir.path)
    let t = FakeTransport([])  // must never be hit
    let uploader = FeedbackUploader(
      config: ShakeToShipConfig(
        app: "dotself", collectorURL: URL(string: "https://c.example.com")!, secret: "s"),
      transport: t, fileManager: .default, outboxRoot: root)

    let result = await uploader.retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 1))
    #expect(FileManager.default.fileExists(atPath: dir.path) == false)
  }
}
