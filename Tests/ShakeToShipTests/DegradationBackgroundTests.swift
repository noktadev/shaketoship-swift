import Foundation
import Testing

@testable import ShakeToShip

@Suite struct DegradationBackgroundTests {
  @Test func backgroundedRecordingRemainsOfferableAfterItsSegmentCloses() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sts-background-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("session", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lifecycle = FeedbackRecordingSession(
      directory: dir, capture: DegradationBackgroundCapture())

    try await lifecycle.start()
    try await lifecycle.pause()
    let segments = await lifecycle.snapshotSegments()
    let session = FeedbackSession(
      session_id: "session", app: "test", build: "1",
      started_at: "2026-08-14T00:00:00Z", events: [], segments: segments)
    let persisted = writeFeedbackPauseDurability(in: dir, session: session)
    let pending = pendingInterruptedSessions(root: root)
    let candidate = try #require(pending.first)
    let offer = FeedbackOfferPlanner.decide(
      scanResult: pending, busy: false, presentationPossible: true,
      scanInFlight: false, now: Date())

    #expect(await lifecycle.state == .paused)
    #expect(segments == [FeedbackRecordingSegment(file: "recording.mov")])
    #expect(persisted)
    #expect(pending.map(\.sessionId) == ["session"])
    #expect(offer == .present(candidate))
    #expect(
      pending.first.map {
        FileManager.default.fileExists(
          atPath: $0.dir.appendingPathComponent("recording.mov").path)
      } == true)
  }
}

private actor DegradationBackgroundCapture: FeedbackCapture {
  private var outputURL: URL?

  func start(to url: URL) async throws {
    try Data("captured-video".utf8).write(to: url)
    outputURL = url
  }

  func stop() async throws -> URL {
    guard let outputURL else { throw FeedbackRecorderError.notRecording }
    self.outputURL = nil
    return outputURL
  }
}
