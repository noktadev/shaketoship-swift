import AVFoundation
import Foundation
import Testing

@testable import ShakeToShip

@Suite struct DegradationDiskFullTests {
  @Test func failedCaptureWriteShowsAMessageAndLeavesNoUploadableSession() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sts-disk-full-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("session", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lifecycle = FeedbackRecordingSession(
      directory: dir, capture: DegradationFailedWriterCapture())
    try await lifecycle.start()

    let failure: Error
    do {
      _ = try await lifecycle.finalize()
      Issue.record("expected the real asset writer to fail")
      return
    } catch {
      failure = error
    }
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.mov").path))

    let message = FeedbackCaptureFailureRecovery.recover(error: failure, in: dir)
    let transport = DegradationNoUploadTransport()
    let uploader = FeedbackUploader(
      config: ShakeToShipConfig(
        app: "test", collectorURL: URL(string: "https://collector.example.com")!, secret: "s"),
      transport: transport, fileManager: .default, outboxRoot: root)
    let sweep = await uploader.retryOutbox(purgeAge: 0)

    #expect(message.hasPrefix("Recording failed:"))
    #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    #expect(sweep == OutboxSweepResult(flushed: 0, queued: 0, purged: 0))
    #expect(await transport.attempts == 0)
  }
}

private actor DegradationFailedWriterCapture: FeedbackCapture {
  private var outputURL: URL?

  func start(to url: URL) async throws {
    outputURL = url
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("partial-capture".utf8).write(to: url.appendingPathComponent("partial"))
  }

  func stop() async throws -> URL {
    guard let outputURL else { throw FeedbackRecorderError.notRecording }
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    _ = try FeedbackCaptureInputs.attach(
      plan: FeedbackCapturePlan(startsScreenCapture: true, capturesMicrophone: false),
      to: writer, width: 640, height: 480)
    guard writer.startWriting() else {
      throw FeedbackRecorderError.writeFailed(writer.error)
    }
    Issue.record("expected startWriting to fail for an output path that is a directory")
    return outputURL
  }
}

private actor DegradationNoUploadTransport: FeedbackTransport {
  private(set) var attempts = 0

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    attempts += 1
    throw URLError(.notConnectedToInternet)
  }

  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (
    Data, HTTPURLResponse
  ) {
    attempts += 1
    throw URLError(.notConnectedToInternet)
  }
}
