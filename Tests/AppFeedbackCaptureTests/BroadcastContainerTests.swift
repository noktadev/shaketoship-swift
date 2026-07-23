import Foundation
import Testing

@testable import AppFeedbackCapture

@Suite struct BroadcastContainerTests {
  private func makeContainer() throws -> (BroadcastContainer, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("bcast-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (BroadcastContainer(containerRoot: root), root)
  }

  private func mint(
    _ container: BroadcastContainer, id: String, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws -> BroadcastManifest {
    try container.mint(
      sessionId: id,
      startedAt: startedAt,
      appBundleId: "com.example.host",
      sdkVersion: "1.2.3",
      hasNarration: true,
      hasAppAudio: true,
      capSeconds: 300)
  }

  @Test func appGroupIdentifierFollowsTheDocumentedShape() {
    #expect(
      BroadcastContainer.appGroupIdentifier(hostBundleId: "com.example.host")
        == "group.com.example.host.shaketoship")
  }

  @Test func mintCreatesTheSessionDirectoryAndARecordingManifest() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    let minted = try mint(container, id: "s1")

    #expect(minted.state == .recording)
    let dir = try container.sessionDirectory("s1")
    #expect(dir == root.appendingPathComponent("broadcasts/s1", isDirectory: true))
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
    #expect(try container.mediaURL("s1").lastPathComponent == "capture.mov")
    #expect(try container.manifestURL("s1").lastPathComponent == "manifest.json")

    // Round-trips off disk, not out of memory.
    #expect(try container.readManifest("s1") == minted)
  }

  @Test func finalizeRewritesTheManifestWithDurationAndByteCount() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try mint(container, id: "s2")
    let payload = Data(repeating: 0xAB, count: 2_048)
    try payload.write(to: container.mediaURL("s2"))

    let finished = try container.finalize(sessionId: "s2", state: .finished, durationSeconds: 42.5)

    #expect(finished.state == .finished)
    #expect(finished.durationSeconds == 42.5)
    #expect(finished.byteCount == 2_048)
    // Declared track presence survives finalization untouched.
    #expect(finished.hasNarration)
    #expect(finished.hasAppAudio)
    #expect(try container.readManifest("s2") == finished)
  }

  @Test func finalizeCanRecordTheCappedOutcome() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try mint(container, id: "s3")
    try Data(repeating: 0x01, count: 16).write(to: container.mediaURL("s3"))

    let capped = try container.finalize(sessionId: "s3", state: .capped, durationSeconds: 300)

    #expect(capped.state == .capped)
    #expect(capped.byteCount == 16)
    #expect(try container.readManifest("s3").state == .capped)
  }

  @Test func finalizeWithNoMediaFileReportsZeroBytes() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try mint(container, id: "s4")

    // The extension can die before AVAssetWriter creates the file at all.
    // Finalizing must still produce a readable manifest, not throw.
    let finished = try container.finalize(sessionId: "s4", state: .aborted, durationSeconds: 0)

    #expect(finished.byteCount == 0)
    #expect(finished.state == .aborted)
    // The terminal state must actually reach disk - a second process (the
    // host app) only ever sees the manifest by reading it back, never the
    // in-memory return value.
    #expect(try container.readManifest("s4") == finished)
  }

  @Test func sweepClassifiesAStaleRecordingAsAbortedAndKeepsItsPartialFile() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    let started = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try mint(container, id: "dead", startedAt: started)
    // A truncated MOV: the extension was killed mid-write. Still evidence.
    try Data(repeating: 0x00, count: 900).write(to: container.mediaURL("dead"))

    let pending = try container.sweep(now: started.addingTimeInterval(3_600), staleAfter: 600)

    let entry = try #require(pending.first { $0.manifest.sessionId == "dead" })
    #expect(entry.manifest.state == .aborted)
    #expect(try entry.mediaURL == container.mediaURL("dead"))
    #expect(entry.byteCount == 900)
    // The reclassification is durable: a second process must see .aborted too.
    #expect(try container.readManifest("dead").state == .aborted)
    #expect(try FileManager.default.fileExists(atPath: container.mediaURL("dead").path))
  }

  @Test func sweepLeavesAFreshRecordingAlone() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    let started = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try mint(container, id: "live", startedAt: started)

    // Still inside the plausible-session window: an extension may be writing to
    // this very directory right now. Touching it would corrupt a live capture.
    let pending = try container.sweep(now: started.addingTimeInterval(30), staleAfter: 600)

    #expect(pending.isEmpty)
    #expect(try container.readManifest("live").state == .recording)
  }

  @Test func sweepReturnsAlreadyTerminalSessionsOldestFirst() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    // Ids are deliberately sort-hostile: alphabetically "a-newest" < "b-oldest",
    // the opposite of the chronological order the sweep must return. If the
    // `.sorted` in `sweep` were deleted, `contentsOfDirectory` returning
    // entries in (or defaulting to) alphabetical order would produce
    // ["a-newest", "b-oldest"] and this test would catch it - unlike names
    // that happen to already sort chronologically.
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try mint(container, id: "a-newest", startedAt: base.addingTimeInterval(100))
    try Data(repeating: 0x02, count: 2).write(to: container.mediaURL("a-newest"))
    _ = try container.finalize(sessionId: "a-newest", state: .finished, durationSeconds: 5)

    _ = try mint(container, id: "b-oldest", startedAt: base)
    try Data(repeating: 0x01, count: 1).write(to: container.mediaURL("b-oldest"))
    _ = try container.finalize(sessionId: "b-oldest", state: .capped, durationSeconds: 300)

    let pending = try container.sweep(now: base.addingTimeInterval(10_000), staleAfter: 600)

    #expect(pending.map(\.manifest.sessionId) == ["b-oldest", "a-newest"])
    #expect(pending.map(\.manifest.state) == [.capped, .finished])
  }

  @Test func sweepDeclaresTrackPresenceFromTheManifestWithoutProbingTheMedia() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    let started = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try container.mint(
      sessionId: "declared",
      startedAt: started,
      appBundleId: "com.example.host",
      sdkVersion: "1.2.3",
      hasNarration: true,
      hasAppAudio: false,
      capSeconds: 300)
    // Deliberately NOT a decodable movie. Anything that opened it to ask
    // "which tracks are here?" would fail or lie; the manifest is the answer.
    try Data("not a movie".utf8).write(to: container.mediaURL("declared"))

    let pending = try container.sweep(now: started.addingTimeInterval(3_600), staleAfter: 600)

    let entry = try #require(pending.first)
    #expect(entry.manifest.hasNarration)
    #expect(entry.manifest.hasAppAudio == false)
    #expect(entry.mediaURL != nil)
  }

  @Test func sweepSurfacesAnEmptySessionWithNoMediaToUpload() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    let started = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try mint(container, id: "nofile", startedAt: started)

    let pending = try container.sweep(now: started.addingTimeInterval(3_600), staleAfter: 600)

    let entry = try #require(pending.first)
    #expect(entry.manifest.state == .aborted)
    // Nothing to upload, but the caller still learns the session existed and
    // can clean it up. A zero-byte file is not evidence.
    #expect(entry.mediaURL == nil)
    #expect(entry.byteCount == 0)
  }

  @Test func sweepIgnoresJunkEntriesInsteadOfThrowing() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
      at: container.sessionDirectory("garbage"), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: container.manifestURL("garbage"))
    try FileManager.default.createDirectory(
      at: container.sessionDirectory("empty"), withIntermediateDirectories: true)

    // One unreadable directory must not hide every other pending upload.
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try mint(container, id: "good", startedAt: started)
    try Data(repeating: 0x03, count: 3).write(to: container.mediaURL("good"))
    _ = try container.finalize(sessionId: "good", state: .finished, durationSeconds: 1)

    let pending = try container.sweep(now: started.addingTimeInterval(3_600), staleAfter: 600)

    #expect(pending.map(\.manifest.sessionId) == ["good"])
  }

  @Test func sweepOnAContainerThatHasNeverRecordedIsEmpty() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try container.sweep(now: Date(), staleAfter: 600).isEmpty)
  }

  @Test func sweepSurvivesAnUnwritableStaleDirectoryAndKeepsHealthySiblingsPending() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    let started = Date(timeIntervalSince1970: 1_700_000_000)

    // Healthy sibling: already finalized, with media to upload. The sweep
    // loop must return this even if another entry's reclassification fails.
    _ = try mint(container, id: "healthy", startedAt: started)
    try Data(repeating: 0x06, count: 6).write(to: container.mediaURL("healthy"))
    _ = try container.finalize(sessionId: "healthy", state: .finished, durationSeconds: 5)

    // Stale `.recording` whose directory cannot be written to right now -
    // simulates the atomic manifest rewrite throwing (file protection while
    // locked, a second host process racing the same directory). Removing
    // write permission on the directory itself blocks the atomic write's
    // temp-file-then-rename, independent of the manifest file's own mode.
    _ = try mint(container, id: "unwritable", startedAt: started)
    let unwritableDir = try container.sessionDirectory("unwritable")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: unwritableDir.path)
    defer {
      // Restore write permission so the outer `root` cleanup can actually
      // remove this directory.
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: unwritableDir.path)
    }

    let pending = try container.sweep(now: started.addingTimeInterval(3_600), staleAfter: 600)

    #expect(pending.map(\.manifest.sessionId).contains("healthy"))
    let unwritableEntry = try #require(pending.first { $0.manifest.sessionId == "unwritable" })
    // The reclassification could not be written to disk. The entry is still
    // surfaced with its un-rewritten `.recording` manifest so the evidence is
    // offered and the repair is retried on the next sweep, rather than the
    // whole sweep throwing and silently dropping "healthy" too.
    #expect(unwritableEntry.manifest.state == .recording)
  }

  @Test func sweepReturnsTheDirectoryNameAsSessionIdEvenWhenTheManifestBodyDisagrees() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    let started = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try mint(container, id: "A", startedAt: started)
    try Data(repeating: 0x05, count: 5).write(to: container.mediaURL("A"))

    // Hand-edit the manifest body to claim a different session id (a
    // restored device backup, a hand-edited container). Directory "A" is
    // still authoritative for every operation, including what `sweep`
    // returns - a stale `.recording` manifest also exercises the `finalize`
    // repair path.
    var manifest = try container.readManifest("A")
    manifest.sessionId = "B"
    try container.write(manifest, to: "A")

    let pending = try container.sweep(now: started.addingTimeInterval(3_600), staleAfter: 600)

    let entry = try #require(pending.first)
    #expect(entry.manifest.sessionId == "A")
    #expect(entry.manifest.state == .aborted)
    // The repair inside `finalize` must have reached disk, not just the
    // in-memory value `sweep` returns - a second process only ever sees the
    // manifest by reading it back. Fails if `manifest.sessionId = sessionId`
    // is removed from `finalize`, even though `sweep` also stamps
    // `manifest.sessionId` on its own return value.
    #expect(try container.readManifest("A").sessionId == "A")

    // The only identifier the returned manifest exposes must be usable with
    // `discard` to remove the directory that was actually swept.
    try container.discard(sessionId: entry.manifest.sessionId)
    #expect(try !FileManager.default.fileExists(atPath: container.sessionDirectory("A").path))
  }

  @Test func discardRemovesTheWholeSessionDirectory() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try mint(container, id: "done")
    try Data(repeating: 0x04, count: 4).write(to: container.mediaURL("done"))

    try container.discard(sessionId: "done")

    #expect(try !FileManager.default.fileExists(atPath: container.sessionDirectory("done").path))
    #expect(try container.sweep(now: Date(), staleAfter: 600).isEmpty)
  }

  @Test func discardIsIdempotentOnASecondCallAndOnANeverMintedId() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try mint(container, id: "done")
    try Data(repeating: 0x04, count: 4).write(to: container.mediaURL("done"))

    try container.discard(sessionId: "done")
    // A second discard on an already-gone directory must not throw.
    try container.discard(sessionId: "done")
    // Nor must one on an id that was never minted.
    try container.discard(sessionId: "never-minted")

    #expect(try !FileManager.default.fileExists(atPath: container.sessionDirectory("done").path))
  }

  // MARK: - Session id validation (mint/discard/path-accessor chokepoint)

  @Test func discardWithAnEmptySessionIdThrowsAndDoesNotWipeBroadcastsRoot() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    // A sibling session that must survive: "" resolves (before the fix) to
    // `broadcastsRoot` itself, so discarding it would recursively delete
    // every pending session, not just a non-existent one.
    _ = try mint(container, id: "kept")

    #expect(throws: BroadcastContainerError.self) {
      try container.discard(sessionId: "")
    }
    #expect(try FileManager.default.fileExists(atPath: container.sessionDirectory("kept").path))
  }

  @Test func discardWithAParentTraversalSessionIdThrowsAndDoesNotEscapeBroadcastsRoot() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try mint(container, id: "kept")

    // ".." resolves (before the fix) to whatever is above `broadcastsRoot`
    // once a real `FileManager` call touches the path - escaping the
    // broadcasts directory entirely, not just deleting siblings inside it.
    #expect(throws: BroadcastContainerError.self) {
      try container.discard(sessionId: "..")
    }
    #expect(try FileManager.default.fileExists(atPath: container.sessionDirectory("kept").path))
  }

  @Test func discardWithAPathSeparatorInTheSessionIdThrowsAndDoesNotEscapeItsOwnDirectory() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try mint(container, id: "kept")

    #expect(throws: BroadcastContainerError.self) {
      try container.discard(sessionId: "kept/../evil")
    }
    #expect(try FileManager.default.fileExists(atPath: container.sessionDirectory("kept").path))
  }

  @Test func discardThrowsWhenRemovalFailsForAReasonOtherThanAlreadyGone() throws {
    let (container, root) = try makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try mint(container, id: "locked")

    // Removing write permission on `broadcastsRoot` (the *parent* of the
    // session directory) blocks `removeItem` from unlinking the session
    // entry from it - the directory removal itself needs write access on
    // its parent, not on itself.
    //
    // NOTE: this assumes a non-root test runner. Root can write through any
    // permission bits, so this chmod would not actually block the removal
    // there and the test would fail to observe the throw.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: container.broadcastsRoot.path)
    defer {
      // Restore write permission so the outer `root` cleanup can actually
      // remove this directory.
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: container.broadcastsRoot.path)
    }

    #expect(throws: (any Error).self) {
      try container.discard(sessionId: "locked")
    }
  }
}
