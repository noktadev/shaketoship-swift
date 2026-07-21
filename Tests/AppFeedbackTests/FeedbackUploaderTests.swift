import Foundation
import Testing

@testable import AppFeedback

@Suite struct FeedbackUploaderTests {
  // MARK: - Fixtures

  private func makeConfig() -> FeedbackConfig {
    FeedbackConfig(
      app: "dotself",
      collectorURL: URL(string: "https://collector.example.com")!,
      secret: "shh")
  }

  /// Creates a fresh temp outbox root with a `<sessionId>/` dir holding both
  /// files plus the `.confirmed` marker, so the dir represents a user-confirmed
  /// session the launch sweep is allowed to upload. `flush` ignores the marker
  /// (it is not whitelisted), so flush-only tests are unaffected.
  private func makeOutbox(sessionId: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-test-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: dir.appendingPathComponent("recording.mov"))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("events.json"))
    try Data().write(to: dir.appendingPathComponent(feedbackConfirmedMarker))
    return root
  }

  private func presignBody() -> Data {
    let json = """
      {"urls":{"recording.mov":"https://r2.example.com/mov","events.json":"https://r2.example.com/json"}}
      """
    return Data(json.utf8)
  }

  // MARK: - Tests

  @Test func presignRequestHasCorrectShape() async throws {
    let root = try makeOutbox(sessionId: "s1")
    let transport = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
    ])
    let uploader = FeedbackUploader(
      config: makeConfig(), transport: transport,
      fileManager: .default, outboxRoot: root)

    _ = await uploader.flush(sessionId: "s1")

    let presign = try #require(transport.requests.first)
    #expect(presign.url?.absoluteString == "https://collector.example.com/presign")
    #expect(presign.httpMethod == "POST")
    #expect(presign.value(forHTTPHeaderField: "x-feedback-secret") == "shh")

    let body = try #require(presign.httpBody)
    let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(obj["app"] as? String == "dotself")
    #expect(obj["sessionId"] as? String == "s1")
    #expect(obj["files"] as? [String] == ["recording.mov", "events.json"])
  }

  @Test func successfulUploadDeletesLocalSessionDir() async throws {
    let root = try makeOutbox(sessionId: "s1")
    let dir = root.appendingPathComponent("s1")
    let transport = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
    ])
    let uploader = FeedbackUploader(
      config: makeConfig(), transport: transport,
      fileManager: .default, outboxRoot: root)

    let ok = await uploader.flush(sessionId: "s1")

    #expect(ok == true)
    #expect(FileManager.default.fileExists(atPath: dir.path) == false)
  }

  @Test func putFailureRetainsLocalFiles() async throws {
    let root = try makeOutbox(sessionId: "s1")
    let dir = root.appendingPathComponent("s1")
    let transport = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 500, data: Data()),  // PUT fails
    ])
    let uploader = FeedbackUploader(
      config: makeConfig(), transport: transport,
      fileManager: .default, outboxRoot: root)

    let ok = await uploader.flush(sessionId: "s1")

    #expect(ok == false)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.mov").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("events.json").path))
  }

  @Test func presignFailureRetainsLocalFiles() async throws {
    let root = try makeOutbox(sessionId: "s1")
    let dir = root.appendingPathComponent("s1")
    let transport = FakeTransport([.init(status: 401, data: Data())])
    let uploader = FeedbackUploader(
      config: makeConfig(), transport: transport,
      fileManager: .default, outboxRoot: root)

    let ok = await uploader.flush(sessionId: "s1")

    #expect(ok == false)
    #expect(FileManager.default.fileExists(atPath: dir.path))
  }

  @Test func retryOutboxSweepsAllSessionDirs() async throws {
    let root = try makeOutbox(sessionId: "s1")
    // add a second session dir under the same root
    let dir2 = root.appendingPathComponent("s2", isDirectory: true)
    try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: dir2.appendingPathComponent("recording.mov"))
    try Data("{}".utf8).write(to: dir2.appendingPathComponent("events.json"))
    try Data().write(to: dir2.appendingPathComponent(feedbackConfirmedMarker))

    // 2 sessions * (1 presign + 2 PUT) all-200 responses
    var stubs: [FakeTransport.Stub] = []
    for _ in 0..<2 {
      stubs.append(.init(status: 200, data: presignBody()))
      stubs.append(.init(status: 200, data: Data()))
      stubs.append(.init(status: 200, data: Data()))
    }
    let transport = FakeTransport(stubs)

    await uploader(root, transport).retryOutbox()

    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("s1").path) == false)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("s2").path) == false)
  }

  @Test func flushUploadsOnlyExistingFiles() async throws {
    // Partial dir: video present, events.json missing (finding 9).
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-test-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("s1", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: dir.appendingPathComponent("recording.mov"))

    let presign = Data(#"{"urls":{"recording.mov":"https://r2.example.com/mov"}}"#.utf8)
    let transport = FakeTransport([
      .init(status: 200, data: presign),
      .init(status: 200, data: Data()),  // single PUT
    ])
    let uploader = FeedbackUploader(
      config: makeConfig(), transport: transport,
      fileManager: .default, outboxRoot: root)

    let ok = await uploader.flush(sessionId: "s1")

    #expect(ok == true)
    #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    // Presign lists only the file that actually exists.
    let body = try #require(transport.requests.first?.httpBody)
    let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(obj["files"] as? [String] == ["recording.mov"])
    #expect(transport.requests.count == 1)  // presign POST only
    #expect(transport.uploads.count == 1)  // 1 PUT, no PUT for missing events.json
  }

  @Test func putStreamsFromDiskWithoutBufferingBody() async throws {
    // The PUT must carry no in-memory body and instead reference the exact
    // session file on disk, so a large recording never doubles memory.
    let root = try makeOutbox(sessionId: "s1")
    let dir = root.appendingPathComponent("s1")
    let transport = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
    ])
    let uploader = FeedbackUploader(
      config: makeConfig(), transport: transport,
      fileManager: .default, outboxRoot: root)

    let ok = await uploader.flush(sessionId: "s1")

    #expect(ok == true)
    #expect(transport.uploads.count == 2)
    let mov = try #require(transport.uploads.first)
    #expect(mov.request.httpMethod == "PUT")
    #expect(mov.request.httpBody == nil)  // streamed, not buffered
    #expect(mov.file.path == dir.appendingPathComponent("recording.mov").path)
    #expect(mov.fileData == Data("video".utf8))  // real on-disk payload
    let events = transport.uploads[1]
    #expect(events.file.path == dir.appendingPathComponent("events.json").path)
    #expect(events.fileData == Data("{}".utf8))
  }

  @Test func deletionFailureReturnsFalse() async throws {
    // Uploads succeed but the local dir cannot be removed => honest false so the
    // outbox is not reported clear while files remain (finding 7).
    let root = try makeOutbox(sessionId: "s1")
    let transport = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
    ])
    let uploader = FeedbackUploader(
      config: makeConfig(), transport: transport,
      fileManager: FailingRemoveFileManager(), outboxRoot: root)

    let ok = await uploader.flush(sessionId: "s1")

    #expect(ok == false)
  }

  // MARK: - Outbox hygiene (zero-file dirs from crashed sessions)

  /// Fresh empty temp root; returns the root URL (created on disk).
  private func makeEmptyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }


  /// Backdates a directory beyond the purge-age guard.
  private func backdate(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: url.path)
  }

  @Test func retryOutboxRetainsFreshEmptyDir() async throws {
    let root = try makeEmptyRoot()
    let fresh = root.appendingPathComponent("live-session", isDirectory: true)
    try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
    let transport = FakeTransport([])

    let result = await uploader(root, transport).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 0))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
  }

  @Test func retryOutboxPurgesZeroFileDir() async throws {
    let root = try makeEmptyRoot()
    let empty = root.appendingPathComponent("crashed", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try backdate(empty)
    let transport = FakeTransport([])  // must never be hit

    let result = await uploader(root, transport).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 1))
    #expect(FileManager.default.fileExists(atPath: empty.path) == false)
    #expect(transport.requests.isEmpty)  // no presign/PUT for a purged dir
    #expect(transport.uploads.isEmpty)
  }

  @Test func retryOutboxPurgesDirWithOnlyNonWhitelistedFiles() async throws {
    let root = try makeEmptyRoot()
    let junkDir = root.appendingPathComponent("junk", isDirectory: true)
    try FileManager.default.createDirectory(at: junkDir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: junkDir.appendingPathComponent("recording.mov.tmp"))
    try backdate(junkDir)
    let transport = FakeTransport([])

    let result = await uploader(root, transport).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 0, purged: 1))
    #expect(FileManager.default.fileExists(atPath: junkDir.path) == false)
    #expect(transport.requests.isEmpty)
    #expect(transport.uploads.isEmpty)
  }

  @Test func retryOutboxFlushesDirWithAtLeastOneFile() async throws {
    let root = try makeOutbox(sessionId: "s1")  // full dir, both files
    let transport = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
    ])

    let result = await uploader(root, transport).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 1, queued: 0, purged: 0))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("s1").path) == false)
  }

  @Test func retryOutboxMixedPurgesEmptyAndFlushesFull() async throws {
    let root = try makeOutbox(sessionId: "full")  // full dir under root
    let empty = root.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try backdate(empty)
    let transport = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 200, data: Data()),
      .init(status: 200, data: Data()),
    ])

    let result = await uploader(root, transport).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 1, queued: 0, purged: 1))
    #expect(FileManager.default.fileExists(atPath: empty.path) == false)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("full").path) == false)
  }

  @Test func retryOutboxRetainsDirWhenUploadFails() async throws {
    let root = try makeOutbox(sessionId: "s1")
    let transport = FakeTransport([
      .init(status: 200, data: presignBody()),
      .init(status: 500, data: Data()),  // PUT fails -> queued, dir kept
    ])

    let result = await uploader(root, transport).retryOutbox()

    #expect(result == OutboxSweepResult(flushed: 0, queued: 1, purged: 0))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("s1").path))
  }

  private func uploader(_ root: URL, _ transport: FakeTransport) -> FeedbackUploader {
    FeedbackUploader(
      config: makeConfig(), transport: transport,
      fileManager: .default, outboxRoot: root)
  }
}

/// FileManager whose `removeItem` always fails; everything else delegates to super.
final class FailingRemoveFileManager: FileManager, @unchecked Sendable {
  override func removeItem(at url: URL) throws {
    throw CocoaError(.fileWriteNoPermission)
  }
}

/// Fake transport returning queued responses and recording requests. `perform`
/// calls (presign POSTs) land in `requests`; `upload` calls (file-streamed PUTs)
/// land in `uploads` as `(request, file, fileData)` - `fileData` is the on-disk
/// content snapshotted at call time so content assertions survive dir deletion.
final class FakeTransport: FeedbackTransport, @unchecked Sendable {
  struct Stub { let status: Int; let data: Data }
  private var responses: [Stub]
  private(set) var requests: [URLRequest] = []
  private(set) var uploads: [(request: URLRequest, file: URL, fileData: Data?)] = []
  private let lock = NSLock()

  init(_ responses: [Stub]) { self.responses = responses }

  /// Pops the next queued stub; a 500 sentinel when the queue is drained. Must
  /// be called while holding `lock`.
  private func nextStub() -> Stub {
    responses.isEmpty ? Stub(status: 500, data: Data()) : responses.removeFirst()
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let stub = lock.withLock {
      requests.append(request)
      return nextStub()
    }
    let resp = HTTPURLResponse(
      url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
    return (stub.data, resp)
  }

  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
    let fileData = try? Data(contentsOf: file)
    let stub = lock.withLock {
      uploads.append((request, file, fileData))
      return nextStub()
    }
    let resp = HTTPURLResponse(
      url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
    return (stub.data, resp)
  }
}
