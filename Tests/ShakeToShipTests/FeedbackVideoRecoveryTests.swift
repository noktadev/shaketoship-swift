import Foundation
import Testing

@testable import ShakeToShip

private actor RecoveryCompressor: FeedbackVideoCompressing {
  enum Failure: Error { case export }
  var count = 0
  let fails: Bool
  init(fails: Bool = false) { self.fails = fails }
  func compress(source: URL, destination: URL, maximumBytes: Int) async throws {
    count += 1
    try Data("smaller complete video".utf8).write(to: destination)
    if fails { throw Failure.export }
  }
}

@Suite struct FeedbackVideoRecoveryTests {
  private let presign = Data(#"{"urls":{"events.json":"https://r2.example/events","recording.mov":"https://r2.example/video","complete.json":"https://r2.example/complete"}}"#.utf8)

  private func fixture(confirmed: Bool = true, rejected: Bool = true) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID())")
    let dir = root.appendingPathComponent("session")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("original complete video".utf8).write(to: dir.appendingPathComponent("recording.mov"))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("events.json"))
    if confirmed { try Data().write(to: dir.appendingPathComponent(feedbackConfirmedMarker)) }
    if rejected {
      try Data(#"{"version":1,"statusCode":413}"#.utf8)
        .write(to: dir.appendingPathComponent(".upload-failure.json"))
    }
    return root
  }

  private func uploader(_ root: URL, _ transport: FakeTransport, _ compressor: RecoveryCompressor) -> FeedbackUploader {
    FeedbackUploader(config: ShakeToShipConfig(app: "test", collectorURL: URL(string: "https://collector.example")!, secret: "test"),
      transport: transport, fileManager: .default, outboxRoot: root, videoCompressor: compressor)
  }

  @Test func legacy413UsesVerifiedCopyAndCompletesOnlyAfterMedia() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let compressor = RecoveryCompressor()
    let transport = FakeTransport([.init(status: 200, data: presign),
      .init(status: 200, data: Data()), .init(status: 200, data: Data()), .init(status: 200, data: Data())])
    let result = await uploader(root, transport, compressor).upload(sessionId: "session")
    #expect(result == .uploaded)
    #expect(await compressor.count == 1)
    #expect(transport.uploads.map(\.file.lastPathComponent) == ["events.json", "recording.mov", "complete.json"])
    #expect(transport.uploads[1].file.deletingLastPathComponent().lastPathComponent == ".upload-recovery")
    #expect(transport.uploads[1].fileData == Data("smaller complete video".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("session").path))
  }

  @Test func failedExportKeepsOriginalAndOnlyProbesCapabilitiesAfterRelaunch() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("session/recording.mov")
    let before = try Data(contentsOf: original)
    let compressor = RecoveryCompressor(fails: true)
    let transport = FakeTransport([.init(status: 200, data: presign), .init(status: 200, data: presign)])
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .recordingTooLarge)
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .recordingTooLarge)
    #expect(await compressor.count == 1)
    #expect(transport.requests.count == 2)
    #expect(transport.uploads.isEmpty)
    #expect(try Data(contentsOf: original) == before)
    #expect(uploader(root, transport, compressor).retainedRecordings().first?.originalFiles.map { $0.resolvingSymlinksInPath() } == [original.resolvingSymlinksInPath()])
  }

  @Test func failedCompletionKeepsOriginalAndRetriesCopyWithoutRecompression() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let compressor = RecoveryCompressor()
    let first = FakeTransport([.init(status: 200, data: presign),
      .init(status: 200, data: Data()), .init(status: 200, data: Data()), .init(status: 500, data: Data())])
    #expect(await uploader(root, first, compressor).upload(sessionId: "session") == .retryableFailure)
    #expect(try Data(contentsOf: root.appendingPathComponent("session/recording.mov")) == Data("original complete video".utf8))
    #expect(uploader(root, first, compressor).retainedRecordings().count == 1)
    let second = FakeTransport([.init(status: 200, data: presign),
      .init(status: 200, data: Data()), .init(status: 200, data: Data())])
    #expect(await uploader(root, second, compressor).upload(sessionId: "session") == .uploaded)
    #expect(await compressor.count == 1)
    #expect(second.uploads.map(\.file.lastPathComponent) == ["recording.mov", "complete.json"])
  }

  @Test func smallerCopyRejectedAgainRemainsExportableAfterCapabilityProbe() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let compressor = RecoveryCompressor()
    let first = FakeTransport([.init(status: 200, data: presign),
      .init(status: 200, data: Data()), .init(status: 413, data: Data())])
    #expect(await uploader(root, first, compressor).upload(sessionId: "session") == .recordingTooLarge)
    let later = FakeTransport([.init(status: 200, data: presign)])
    #expect(await uploader(root, later, compressor).upload(sessionId: "session") == .recordingTooLarge)
    #expect(later.requests.count == 1)
    #expect(later.uploads.isEmpty)
    #expect(await compressor.count == 1)
    #expect(uploader(root, later, compressor).retainedRecordings().count == 1)
    #expect(!first.uploads.contains { $0.file.lastPathComponent == "complete.json" })
  }

  @Test func unconfirmedRecordingIsNeitherRecoveredNorExposedForExport() async throws {
    let root = try fixture(confirmed: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let compressor = RecoveryCompressor()
    let transport = FakeTransport([])
    let service = uploader(root, transport, compressor)
    #expect(await service.upload(sessionId: "session") == .recordingTooLarge)
    #expect(service.retainedRecordings().isEmpty)
    #expect(await compressor.count == 0)
    #expect(transport.requests.isEmpty)
  }

  @Test func interruptedAttemptKeepsOriginalAvailableWithoutRestartingExport() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"ready":false,"files":{}}"#.utf8).write(to: root.appendingPathComponent("session/.video-recovery.json"))
    let compressor = RecoveryCompressor()
    let transport = FakeTransport([.init(status: 200, data: presign)])
    let service = uploader(root, transport, compressor)
    #expect(await service.upload(sessionId: "session") == .recordingTooLarge)
    #expect(await compressor.count == 0)
    #expect(service.retainedRecordings().first?.originalFiles.count == 1)
  }

  @Test func readyCopyResumesAfterCrashBeforeLegacyFailureMarkerRemoval() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let compressor = RecoveryCompressor()
    let recovery = FeedbackVideoRecovery(compressor: compressor, fileManager: .default)
    #expect(await recovery.prepare(in: root.appendingPathComponent("session"), names: ["recording.mov"]))
    // The legacy 413 marker still exists, but no smaller-copy request occurred.
    let transport = FakeTransport([.init(status: 200, data: presign),
      .init(status: 200, data: Data()), .init(status: 200, data: Data()), .init(status: 200, data: Data())])
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .uploaded)
    #expect(await compressor.count == 1)
  }

  @Test func largeRecordingUsesCompressionAfterLegacyCapabilityProbe() async throws {
    let root = try fixture(rejected: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("session/recording.mov")
    let file = try FileHandle(forWritingTo: original)
    try file.truncate(atOffset: UInt64(FeedbackVideoRecovery.maximumBytes + 1))
    try file.close()
    let compressor = RecoveryCompressor()
    let transport = FakeTransport([.init(status: 200, data: presign),
      .init(status: 200, data: Data()), .init(status: 200, data: Data()), .init(status: 200, data: Data())])
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .uploaded)
    #expect(await compressor.count == 1)
    #expect(transport.uploads[1].fileData == Data("smaller complete video".utf8))
  }

  @Test func verificationRejectsTruncationAndDroppedAudio() {
    let original = FeedbackVideoMeasurements(duration: 120, videoTracks: 1, audioTracks: 1)
    #expect(FeedbackVideoMeasurements(duration: 120.02, videoTracks: 1, audioTracks: 1).preserves(original))
    #expect(!FeedbackVideoMeasurements(duration: 60, videoTracks: 1, audioTracks: 1).preserves(original))
    #expect(!FeedbackVideoMeasurements(duration: 120, videoTracks: 1, audioTracks: 0).preserves(original))
    #expect(!FeedbackVideoMeasurements(duration: .nan, videoTracks: 1, audioTracks: 1).preserves(original))
  }
}
