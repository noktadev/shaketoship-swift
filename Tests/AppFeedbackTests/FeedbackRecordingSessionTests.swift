import Foundation
import Testing

@testable import AppFeedback

@Suite struct FeedbackRecordingSessionTests {
  @Test func backgroundPauseAndForegroundResumeKeepOneSessionOpen() async throws {
    let capture = CaptureStub()
    let dir = URL(fileURLWithPath: "/feedback/s1", isDirectory: true)
    let session = FeedbackRecordingSession(directory: dir, capture: capture)

    try await session.start()
    #expect(await session.state == .recording)

    try await session.pause()
    #expect(await session.state == .paused)

    try await session.resume()
    #expect(await session.state == .recording)

    let segments = try await session.finalize()
    #expect(await session.state == .finalized)
    #expect(segments.map(\.file) == ["recording.mov", "recording-002.mov"])
  }

  @Test func emptyResumedSegmentDoesNotDiscardEarlierCapture() async throws {
    let capture = CaptureStub()
    let session = FeedbackRecordingSession(
      directory: URL(fileURLWithPath: "/feedback/s1", isDirectory: true),
      capture: capture)

    try await session.start()
    try await session.pause()
    try await session.resume()
    await capture.makeNextStopEmpty()

    let segments = try await session.finalize()

    #expect(await session.state == .finalized)
    #expect(segments.map(\.file) == ["recording.mov"])
  }

  /// #669 MUST-FIX 3: a pause that fails for a reason OTHER than
  /// `.emptyRecording` (e.g. `.writeFailed`) must still fold the state
  /// machine into `.paused`, so `finalize()` never re-invokes
  /// `capture.stop()` for a segment the capture already tried (and failed) to
  /// close. Before the fix, `state` stayed `.recording`, `finalize()` called
  /// `finishCurrentSegment()` a second time, and the stub's second `.stop()`
  /// throwing `.notRecording` propagated out of `finalize()` uncaught -
  /// exactly the double-stop that let the caller nuke a session dir
  /// containing an earlier valid segment.
  @Test func failedPauseFoldsToPausedAndFinalizeNeverDoubleStops() async throws {
    let capture = CaptureStub()
    let session = FeedbackRecordingSession(
      directory: URL(fileURLWithPath: "/feedback/s1", isDirectory: true),
      capture: capture)

    try await session.start()
    try await session.pause()
    try await session.resume()

    await capture.makeNextStopThrow(.writeFailed(nil))
    await #expect(throws: FeedbackRecorderError.self) {
      try await session.pause()
    }
    #expect(await session.state == .paused)

    // If `finalize()` regressed to double-stopping, this would be consumed by
    // that second call and surface as a thrown `.notRecording` instead of a
    // clean finalize.
    await capture.makeNextStopThrow(.notRecording)

    let segments = try await session.finalize()

    #expect(await session.state == .finalized)
    #expect(segments.map(\.file) == ["recording.mov"])
    #expect(await capture.stopCallCount == 2)
  }
}

private actor CaptureStub: FeedbackCapture {
  private var outputURL: URL?
  private var nextStopIsEmpty = false
  private var nextStopError: FeedbackRecorderError?
  private(set) var stopCallCount = 0

  func start(to url: URL) async throws {
    outputURL = url
  }

  func stop() async throws -> URL {
    stopCallCount += 1
    if let error = nextStopError {
      nextStopError = nil
      outputURL = nil
      throw error
    }
    if nextStopIsEmpty {
      nextStopIsEmpty = false
      outputURL = nil
      throw FeedbackRecorderError.emptyRecording
    }
    let url = try #require(outputURL)
    outputURL = nil
    return url
  }

  func makeNextStopEmpty() {
    nextStopIsEmpty = true
  }

  func makeNextStopThrow(_ error: FeedbackRecorderError) {
    nextStopError = error
  }
}
