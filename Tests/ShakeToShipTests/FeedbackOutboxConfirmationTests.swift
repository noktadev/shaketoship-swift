import Foundation
import Testing

@testable import ShakeToShip

@Suite struct FeedbackOutboxConfirmationTests {
  private func makeConfig() -> ShakeToShipConfig {
    ShakeToShipConfig(
      app: "dotself",
      collectorURL: URL(string: "https://collector.example.com")!,
      secret: "shh")
  }

  private func presignBody() -> Data {
    Data(
      #"{"urls":{"recording.mov":"https://r2/mov","events.json":"https://r2/json","complete.json":"https://r2/complete"}}"#.utf8)
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-conf-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// Session dir with both whitelisted files; `confirmed` adds the marker.
  @discardableResult
  private func makeSession(_ root: URL, _ id: String, confirmed: Bool) throws -> URL {
    let dir = root.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: dir.appendingPathComponent("recording.mov"))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("events.json"))
    if confirmed {
      try Data().write(to: dir.appendingPathComponent(feedbackConfirmedMarker))
    }
    return dir
  }

  private func backdate(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: url.path)
  }

  private func uploader(_ root: URL, _ t: FakeTransport) -> FeedbackUploader {
    FeedbackUploader(config: makeConfig(), transport: t, fileManager: .default, outboxRoot: root)
  }

  @Test func confirmedDirIsFlushed() async throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", confirmed: true)
    let t = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
    ])

    let result = await uploader(root, t).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 1, queued: 0, purged: 0))
    #expect(FileManager.default.fileExists(atPath: dir.path) == false)
  }

  @Test func unconfirmedFreshDirIsUntouched() async throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", confirmed: false)
    let t = FakeTransport([])  // must never be hit

    let result = await uploader(root, t).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 0))
    #expect(FileManager.default.fileExists(atPath: dir.path))
    #expect(t.requests.isEmpty)
    #expect(t.uploads.isEmpty)
  }

  @Test func unconfirmedStaleDirIsPurged() async throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", confirmed: false)
    try backdate(dir)
    let t = FakeTransport([])  // must never be hit

    let result = await uploader(root, t).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 1))
    #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    #expect(t.requests.isEmpty)
    #expect(t.uploads.isEmpty)
  }

  @Test func markerNeverAppearsInPresignOrUploadFileList() async throws {
    let root = try makeRoot()
    try makeSession(root, "s1", confirmed: true)
    let t = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
    ])

    _ = await uploader(root, t).flush(sessionId: "s1")

    let presign = try #require(t.requests.first)
    let body = try #require(presign.httpBody)
    let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(obj["files"] as? [String] == ["events.json", "recording.mov", "complete.json"])
    // Presign POST + evidence and sentinel PUTs. The marker never appears.
    #expect(t.requests.count == 1)
    #expect(t.uploads.count == 3)
  }

  @Test func markerWriteSucceedsAndLandsOnDisk() throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", confirmed: false)

    #expect(writeFeedbackConfirmedMarker(in: dir))
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(feedbackConfirmedMarker).path))
  }

  @Test func markerWriteRetriesOnceAfterTransientFailure() throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", confirmed: false)
    var attempts = 0

    let ok = writeFeedbackConfirmedMarker(in: dir) { url in
      attempts += 1
      if attempts == 1 { throw CocoaError(.fileWriteUnknown) }
      try Data().write(to: url)
    }

    #expect(ok)
    #expect(attempts == 2)
  }

  @Test func markerWriteGivesUpAfterTwoAttempts() throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", confirmed: false)
    var attempts = 0

    let ok = writeFeedbackConfirmedMarker(in: dir) { _ in
      attempts += 1
      throw CocoaError(.fileWriteUnknown)
    }

    #expect(ok == false)
    #expect(attempts == 2)
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(feedbackConfirmedMarker).path) == false)
  }

  @Test func markerWriteToMissingDirFails() throws {
    let root = try makeRoot()
    let dir = root.appendingPathComponent("does-not-exist", isDirectory: true)

    #expect(writeFeedbackConfirmedMarker(in: dir) == false)
  }

  /// `FileManager` deletion is the non-deterministic leaf here: the real one
  /// cannot be made to fail in a tmp dir, so only `removeItem` is stubbed - all
  /// directory reads still hit the real tmp FS.
  private final class UndeletableFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
      throw CocoaError(.fileWriteNoPermission)
    }
  }

  @Test func purgeCountsOnlyActualRemovals() async throws {
    let root = try makeRoot()
    let dir = try makeSession(root, "s1", confirmed: false)
    try backdate(dir)
    let t = FakeTransport([])  // must never be hit

    let uploader = FeedbackUploader(
      config: makeConfig(), transport: t,
      fileManager: UndeletableFileManager(), outboxRoot: root)
    let result = await uploader.retryOutbox()

    // Deletion failed, so purged must stay 0 - the dir is still on disk and
    // reporting it purged would be a lie.
    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 0))
    #expect(FileManager.default.fileExists(atPath: dir.path))
  }
}
