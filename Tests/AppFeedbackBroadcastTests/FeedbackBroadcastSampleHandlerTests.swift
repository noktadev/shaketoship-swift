import AVFoundation
import CaptureTestSupport
import CoreMedia
import Foundation
import ReplayKit
import Testing

@testable import AppFeedbackBroadcast
@testable import AppFeedbackCapture

/// Drives the REAL `RPBroadcastSampleHandler` subclass - the exact class a
/// customer's six-line `SampleHandler` inherits from - through the exact three
/// callbacks ReplayKit invokes, and then reads the resulting file and manifest
/// off disk.
///
/// Verified before writing any of it: `RPBroadcastSampleHandler` is
/// `API_AVAILABLE(macos(11.0))` and instantiates and runs outside an extension
/// host, so none of this needs a device or a stand-in base class. The only
/// thing overridden is where the session's container comes from - a temp
/// directory instead of a real App Group, which no test process has.
@Suite struct FeedbackBroadcastSampleHandlerTests {
  /// What a customer writes, plus a container the test can inspect.
  private final class TestHandler: FeedbackBroadcastSampleHandler {
    let container: BroadcastContainer
    let sessionId = UUID().uuidString
    private(set) var startupError: Error?

    init(containerRoot: URL) {
      self.container = BroadcastContainer(containerRoot: containerRoot)
      super.init()
    }

    override func makeSession() throws -> BroadcastCaptureSession {
      BroadcastCaptureSession(
        container: container,
        sessionId: sessionId,
        config: FeedbackBroadcastConfiguration(hostBundleId: "com.example.app"),
        narrationSampleRate: 44_100,
        appAudioSampleRate: 22_050)
    }

    /// `finishBroadcastWithError` tears the extension process down, which is
    /// not a thing a test process can survive - so the failure path is
    /// observed here instead of being fired for real.
    override func failBroadcast(_ error: Error) {
      startupError = error
    }
  }

  private func makeHandler() -> (TestHandler, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("broadcast-handler-\(UUID().uuidString)", isDirectory: true)
    return (TestHandler(containerRoot: root), root)
  }

  /// See `BroadcastCaptureSessionTests.finish(_:)`: `broadcastFinished` blocks
  /// on a bounded semaphore by design, and blocking a swift-testing cooperative
  /// thread starves the pool.
  private func broadcastFinished(_ handler: TestHandler) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        handler.broadcastFinished()
        continuation.resume()
      }
    }
  }

  @Test func broadcastStartedPublishesARecordingSession() throws {
    let (handler, root) = makeHandler()
    defer { try? FileManager.default.removeItem(at: root) }

    handler.broadcastStarted(withSetupInfo: nil)

    #expect(handler.startupError == nil)
    let manifest = try handler.container.readManifest(handler.sessionId)
    #expect(manifest.state == .recording)
  }

  @Test func theFullReplayKitCallbackSequenceProducesAFinishedRecording() async throws {
    // start -> buffers of all three types -> finish, as ReplayKit drives it.
    let (handler, root) = makeHandler()
    defer { try? FileManager.default.removeItem(at: root) }

    handler.broadcastStarted(withSetupInfo: nil)
    for index in 0..<10 {
      handler.processSampleBuffer(
        try #require(
          CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: index))),
        with: .video)
      handler.processSampleBuffer(
        try #require(
          CaptureSampleFactory.audioSample(at: CaptureSampleFactory.audioPTS(bufferIndex: index))),
        with: .audioMic)
      handler.processSampleBuffer(
        try #require(
          CaptureSampleFactory.audioSample(
            at: CaptureSampleFactory.audioPTS(bufferIndex: index, sampleRate: 22_050),
            sampleRate: 22_050)),
        with: .audioApp)
    }
    await broadcastFinished(handler)

    let manifest = try handler.container.readManifest(handler.sessionId)
    #expect(manifest.state == .finished)
    #expect((manifest.byteCount ?? 0) > 0)
    #expect(manifest.hasNarration)
    #expect(manifest.hasAppAudio)

    // The artifact itself, not just the bookkeeping: three real tracks in one
    // file, which is only true if the handler routed all three buffer types
    // through to distinct writer inputs.
    let asset = AVURLAsset(url: try handler.container.mediaURL(handler.sessionId))
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 2)
  }

  @Test func buffersDeliveredBeforeBroadcastStartedAreIgnored() throws {
    // ReplayKit has been observed delivering a buffer before the start callback
    // returns. There is no session to route it to yet, and it must not crash.
    let (handler, root) = makeHandler()
    defer { try? FileManager.default.removeItem(at: root) }

    handler.processSampleBuffer(
      try #require(CaptureSampleFactory.videoSample(at: .zero)), with: .video)

    #expect(
      FileManager.default.fileExists(
        atPath: try handler.container.sessionDirectory(handler.sessionId).path) == false)
  }

  @Test func broadcastFinishedWithoutAStartIsANoOp() async {
    let (handler, root) = makeHandler()
    defer { try? FileManager.default.removeItem(at: root) }

    await broadcastFinished(handler)

    #expect(handler.startupError == nil)
  }

  @Test func aFailureToMintASessionFailsTheBroadcastInsteadOfRecordingNowhere() throws {
    // The App Group is the whole handoff. If the session cannot be minted there
    // is nowhere for the host app to read from, so the broadcast must be failed
    // rather than left running and recording into nothing.
    final class UnmintableHandler: FeedbackBroadcastSampleHandler {
      private(set) var failure: Error?
      override func makeSession() throws -> BroadcastCaptureSession {
        throw BroadcastCaptureSessionError.containerUnavailable
      }
      override func failBroadcast(_ error: Error) { failure = error }
    }

    let handler = UnmintableHandler()
    handler.broadcastStarted(withSetupInfo: nil)

    #expect(
      handler.failure as? BroadcastCaptureSessionError == .containerUnavailable)
    // And a buffer arriving afterwards still must not crash.
    handler.processSampleBuffer(
      try #require(CaptureSampleFactory.videoSample(at: .zero)), with: .video)
  }

  @Test func theDefaultSessionFactoryRefusesWithoutConfiguration() {
    // The stock handler resolves its config from `Bundle.main`, which in this
    // test process is the test runner - no `AppFeedbackHostBundleId`. That must
    // surface as a refusal, never as a session minted against a guessed group.
    let handler = FeedbackBroadcastSampleHandler()
    #expect(throws: BroadcastCaptureSessionError.self) { try handler.makeSession() }
  }
}
