import AppFeedbackCapture
import Foundation
import Testing

@testable import AppFeedback

/// Harvest runs against a REAL container on disk, a real `BroadcastContainer`
/// sweep, and a real `FeedbackUploader`. The only double is `FeedbackTransport`
/// (the network), which the uploader already exposes as a seam. Every
/// assertion about what survived is a `fileExists` against the actual
/// directory, so a harvest that "reported" a deletion it never made fails here.
@Suite struct FeedbackBroadcastHarvestTests {
  // MARK: - Fixtures

  private func makeContainer() throws -> BroadcastContainer {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-harvest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return BroadcastContainer(containerRoot: root)
  }

  /// Mints a real session directory with a real manifest and real media bytes.
  @discardableResult
  private func makeSession(
    in container: BroadcastContainer,
    id: String,
    startedAt: Date,
    state: BroadcastManifest.State?,
    media: String? = "capture-bytes"
  ) throws -> String {
    try container.mint(
      sessionId: id,
      startedAt: startedAt,
      appBundleId: "com.example.app",
      sdkVersion: "1.0.0",
      hasNarration: true,
      hasAppAudio: false,
      capSeconds: 300)
    if let media {
      try Data(media.utf8).write(to: container.mediaURL(id))
    }
    if let state {
      try container.finalize(sessionId: id, state: state, durationSeconds: 12)
    }
    return id
  }

  private func makeManager(
    container: BroadcastContainer, transport: FeedbackTransport
  ) -> FeedbackBroadcastManager {
    FeedbackBroadcastManager(
      appGroupIdentifier: "group.test.\(UUID().uuidString).shaketoship",
      uploader: FeedbackUploader(
        config: FeedbackConfig(
          app: "dotself",
          collectorURL: URL(string: "https://collector.example.com")!,
          secret: "shh"),
        transport: transport,
        fileManager: .default,
        outboxRoot: container.containerRoot),
      containerProvider: { container })
  }

  /// A presign response granting PUT URLs for the broadcast pair.
  private func presignStub() -> FakeTransport.Stub {
    let body = """
      {"urls":{"capture.mov":"https://r2.example.com/capture","manifest.json":"https://r2.example.com/manifest"}}
      """
    return FakeTransport.Stub(status: 200, data: Data(body.utf8))
  }

  private func ok() -> FakeTransport.Stub { FakeTransport.Stub(status: 200, data: Data()) }

  private func exists(_ container: BroadcastContainer, _ sessionId: String) throws -> Bool {
    FileManager.default.fileExists(atPath: try container.sessionDirectory(sessionId).path)
  }

  // MARK: - Selection

  @Test func uploadsFinishedAndStaleRecordingSessionsButLeavesALiveOneAlone() async throws {
    let container = try makeContainer()
    let now = Date()
    // Oldest first, which is also the order `sweep` returns them in.
    try makeSession(
      in: container, id: "stale", startedAt: now.addingTimeInterval(-7200), state: nil,
      media: "truncated")
    try makeSession(
      in: container, id: "done", startedAt: now.addingTimeInterval(-600), state: .finished)
    try makeSession(in: container, id: "live", startedAt: now, state: nil)
    // 2 sessions x (1 presign + 2 PUTs).
    let transport = FakeTransport([
      presignStub(), ok(), ok(),
      presignStub(), ok(), ok(),
    ])
    let manager = makeManager(container: container, transport: transport)

    let result = try await manager.harvest(now: now, staleAfter: 3600)

    #expect(result.uploaded == ["stale", "done"])
    #expect(result.retained.isEmpty)
    #expect(try exists(container, "stale") == false)
    #expect(try exists(container, "done") == false)
    // A session inside its staleness window may have an extension appending to
    // it right now; uploading and deleting it would destroy a live recording.
    #expect(try exists(container, "live") == true)
  }

  @Test func uploadsTheTruncatedMediaOfAKilledExtensionRatherThanDiscardingIt() async throws {
    let container = try makeContainer()
    let now = Date()
    try makeSession(
      in: container, id: "killed", startedAt: now.addingTimeInterval(-7200), state: nil,
      media: "partial-but-real-evidence")
    let transport = FakeTransport([presignStub(), ok(), ok()])
    let manager = makeManager(container: container, transport: transport)

    let result = try await manager.harvest(now: now, staleAfter: 3600)

    #expect(result.uploaded == ["killed"])
    let media = transport.uploads.first { $0.request.url?.absoluteString.contains("capture") == true }
    #expect(media?.fileData == Data("partial-but-real-evidence".utf8))
    // And the manifest went with it, carrying the reclassified state.
    let manifestUpload = try #require(
      transport.uploads.first { $0.request.url?.absoluteString.contains("manifest") == true })
    let manifest = try BroadcastManifest.decoder.decode(
      BroadcastManifest.self, from: try #require(manifestUpload.fileData))
    #expect(manifest.state == .aborted)
  }

  @Test func uploadsBothTheMediaAndTheManifestForEverySession() async throws {
    let container = try makeContainer()
    let now = Date()
    try makeSession(in: container, id: "done", startedAt: now, state: .finished)
    let transport = FakeTransport([presignStub(), ok(), ok()])
    let manager = makeManager(container: container, transport: transport)

    _ = try await manager.harvest(now: now, staleAfter: 3600)

    let names = transport.uploads.map { $0.file.lastPathComponent }.sorted()
    #expect(names == ["capture.mov", "manifest.json"])
    // Uploaded straight from the App Group container: a ~100 MB capture is
    // never copied into the app's own outbox first.
    #expect(transport.uploads.allSatisfy { $0.file.path.contains("/broadcasts/") })
  }

  // MARK: - Delete only after a confirmed upload

  @Test func aFailedMediaUploadLeavesTheSessionOnDisk() async throws {
    let container = try makeContainer()
    let now = Date()
    try makeSession(in: container, id: "done", startedAt: now, state: .finished)
    // Presign succeeds, the media PUT is rejected.
    let transport = FakeTransport([presignStub(), FakeTransport.Stub(status: 500, data: Data())])
    let manager = makeManager(container: container, transport: transport)

    let result = try await manager.harvest(now: now, staleAfter: 3600)

    #expect(result.uploaded.isEmpty)
    #expect(result.retained == ["done"])
    #expect(try exists(container, "done") == true)
    // The evidence itself is untouched, so the next foreground can retry it.
    #expect(
      try Data(contentsOf: container.mediaURL("done")) == Data("capture-bytes".utf8))
  }

  @Test func aFailedPresignLeavesTheSessionOnDisk() async throws {
    let container = try makeContainer()
    let now = Date()
    try makeSession(in: container, id: "done", startedAt: now, state: .finished)
    let transport = FakeTransport([FakeTransport.Stub(status: 503, data: Data())])
    let manager = makeManager(container: container, transport: transport)

    let result = try await manager.harvest(now: now, staleAfter: 3600)

    #expect(result.retained == ["done"])
    #expect(try exists(container, "done") == true)
  }

  @Test func aFailedSessionDoesNotStopTheHealthyOneBehindIt() async throws {
    let container = try makeContainer()
    let now = Date()
    try makeSession(
      in: container, id: "first", startedAt: now.addingTimeInterval(-600), state: .finished)
    try makeSession(in: container, id: "second", startedAt: now, state: .finished)
    let transport = FakeTransport([
      FakeTransport.Stub(status: 503, data: Data()),
      presignStub(), ok(), ok(),
    ])
    let manager = makeManager(container: container, transport: transport)

    let result = try await manager.harvest(now: now, staleAfter: 3600)

    #expect(result.retained == ["first"])
    #expect(result.uploaded == ["second"])
    #expect(try exists(container, "first") == true)
    #expect(try exists(container, "second") == false)
  }

  @Test func aSessionThatNeverGotAByteIsReportedButNeverDeleted() async throws {
    let container = try makeContainer()
    let now = Date()
    try makeSession(in: container, id: "empty", startedAt: now, state: .finished, media: nil)
    let transport = FakeTransport([])
    let manager = makeManager(container: container, transport: transport)

    let result = try await manager.harvest(now: now, staleAfter: 3600)

    #expect(result.empty == ["empty"])
    #expect(result.uploaded.isEmpty)
    #expect(transport.uploads.isEmpty)
    // Deleting it would be a delete without a confirmed upload, which is the
    // one thing this path must never do.
    #expect(try exists(container, "empty") == true)
  }

  @Test func anEmptyContainerHarvestsToNothingWithoutTouchingTheNetwork() async throws {
    let container = try makeContainer()
    let transport = FakeTransport([])
    let manager = makeManager(container: container, transport: transport)

    let result = try await manager.harvest(now: Date(), staleAfter: 3600)

    #expect(result == BroadcastHarvestResult(uploaded: [], retained: [], empty: []))
    #expect(transport.requests.isEmpty)
  }
}
