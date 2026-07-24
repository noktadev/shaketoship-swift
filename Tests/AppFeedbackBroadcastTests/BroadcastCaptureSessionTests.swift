import AVFoundation
import CaptureTestSupport
import CoreMedia
import Foundation
import ReplayKit
import Testing

@testable import AppFeedbackBroadcast
@testable import AppFeedbackCapture

/// Everything here runs the REAL session against a REAL `AVAssetWriter`, a real
/// temp App Group container, and real `CMSampleBuffer`s of the same shapes
/// ReplayKit delivers, then reads the finished `.mov` back. Nothing on the
/// capture path is stubbed - the point of the chunk is which physical track a
/// buffer lands in, and a stub cannot answer that.
@Suite struct BroadcastCaptureSessionTests {
  /// Distinct configured sample rates give the two audio inputs a marker that
  /// survives into the finished file. `capture-core` established that an
  /// AVAssetWriter output track reports its INPUT's configured
  /// `outputSettings` rate, not the shape of the PCM fed to it - so the rate
  /// names which physical input actually received buffers.
  private static let narrationRate: Double = 44_100
  private static let appAudioRate: Double = 22_050

  private func makeContainer() -> (BroadcastContainer, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("broadcast-session-\(UUID().uuidString)", isDirectory: true)
    return (BroadcastContainer(containerRoot: root), root)
  }

  private func makeSession(
    container: BroadcastContainer,
    sessionId: String = UUID().uuidString,
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    capSeconds: Double = 600
  ) -> BroadcastCaptureSession {
    BroadcastCaptureSession(
      container: container,
      sessionId: sessionId,
      config: FeedbackBroadcastConfiguration(
        hostBundleId: "com.example.app", capSeconds: capSeconds),
      startedAt: startedAt,
      narrationSampleRate: Self.narrationRate,
      appAudioSampleRate: Self.appAudioRate)
  }

  /// Feeds buffers the way ReplayKit does - through `process(_:with:)`, one
  /// `RPSampleBufferType` at a time.
  private func feedVideo(_ session: BroadcastCaptureSession, frames: Int) throws {
    for index in 0..<frames {
      let sample = try #require(
        CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: index)))
      session.process(sample, with: .video)
    }
  }

  private func feedAudio(
    _ session: BroadcastCaptureSession, type: RPSampleBufferType, buffers: Int, rate: Double
  ) throws {
    for index in 0..<buffers {
      let sample = try #require(
        CaptureSampleFactory.audioSample(
          at: CaptureSampleFactory.audioPTS(bufferIndex: index, sampleRate: rate),
          sampleRate: rate))
      session.process(sample, with: type)
    }
  }

  /// Runs `finish()` off the Swift concurrency cooperative pool.
  ///
  /// `finish()` is synchronous on purpose: `broadcastFinished` is synchronous
  /// and the extension process is torn down when it returns, so there is
  /// nowhere to defer the finalize to and it blocks on a bounded semaphore. In
  /// the extension the blocked caller is a ReplayKit system thread, which is
  /// exactly where that belongs.
  ///
  /// Under swift-testing every test body runs on the cooperative pool instead,
  /// and this suite runs eleven of them in parallel. Measured on this machine
  /// (12 cores): serially all pass in 1.8 s, in parallel every single finalize
  /// hit its 4 s timeout and reported `.aborted`. Hopping to libdispatch here
  /// keeps the production API the right shape rather than making it `async` for
  /// the test harness's benefit.
  private func finish(_ session: BroadcastCaptureSession) async -> BroadcastManifest? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(returning: session.finish()) }
    }
  }

  private func tracks(_ url: URL) async throws -> (video: Int, audio: Int) {
    let asset = AVURLAsset(url: url)
    return (
      try await asset.loadTracks(withMediaType: .video).count,
      try await asset.loadTracks(withMediaType: .audio).count
    )
  }

  /// Sample rate -> duration, for every audio track in the file. The rate is the
  /// track's identity (which input received it); the duration is what it
  /// received.
  private func audioTracksByRate(_ url: URL) async throws -> [Double: Double] {
    let asset = AVURLAsset(url: url)
    var byRate: [Double: Double] = [:]
    for track in try await asset.loadTracks(withMediaType: .audio) {
      let descriptions = try await track.load(.formatDescriptions)
      guard let description = descriptions.first,
        let rate = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mSampleRate
      else { continue }
      byRate[rate] = CMTimeGetSeconds(try await track.load(.timeRange).duration)
    }
    return byRate
  }

  // MARK: - Session lifecycle

  @Test func startPublishesARecordingManifestBeforeAnyMediaExists() throws {
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    try session.start()

    // The manifest has to be on disk before the first byte of media: if the
    // extension is killed one instruction later, the host app's sweep still
    // finds the session and can classify it.
    let manifest = try container.readManifest(sessionId)
    #expect(manifest.state == .recording)
    #expect(manifest.sessionId == sessionId)
    #expect(manifest.appBundleId == "com.example.app")
    #expect(manifest.capSeconds == 600)
    #expect(
      FileManager.default.fileExists(atPath: try container.sessionDirectory(sessionId).path))
  }

  @Test func finishWritesAFinishedManifestAndAPlayableFile() async throws {
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    try session.start()
    try feedVideo(session, frames: 12)
    try feedAudio(session, type: .audioMic, buffers: 8, rate: Self.narrationRate)
    let manifest = try #require(await finish(session))

    #expect(manifest.state == .finished)
    #expect((manifest.byteCount ?? 0) > 0)
    #expect((manifest.durationSeconds ?? 0) > 0)

    // The manifest on disk must agree with the one returned - the host app only
    // ever sees the disk copy.
    let onDisk = try container.readManifest(sessionId)
    #expect(onDisk.state == .finished)
    #expect(onDisk.byteCount == manifest.byteCount)

    let media = try container.mediaURL(sessionId)
    #expect(FileManager.default.fileExists(atPath: media.path))
    let counts = try await tracks(media)
    #expect(counts.video == 1)
    #expect(counts.audio == 1)
    #expect(CMTimeGetSeconds(try await AVURLAsset(url: media).load(.duration)) > 0)
  }

  @Test func aSessionThatNeverReceivedABufferIsAbortedRatherThanFinalized() async throws {
    // The user starts a broadcast and stops it before a single frame arrives.
    // `AVAssetWriter.finishWriting` would violate its own preconditions here,
    // so the session must cancel instead - and say so, rather than publishing a
    // `.finished` manifest pointing at nothing.
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    try session.start()
    let manifest = try #require(await finish(session))

    #expect(manifest.state == .aborted)
    #expect(manifest.byteCount == 0)
    let media = try container.mediaURL(sessionId)
    #expect(FileManager.default.fileExists(atPath: media.path) == false)
  }

  @Test func processIsANoOpBeforeStartAndAfterFinish() async throws {
    // ReplayKit can deliver a buffer either side of the lifecycle callbacks.
    // Neither may touch a writer that does not exist yet or is already
    // finalized.
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    let early = try #require(
      CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: 0)))
    session.process(early, with: .video)

    try session.start()
    try feedVideo(session, frames: 6)
    let manifest = try #require(await finish(session))
    #expect(manifest.state == .finished)

    let late = try #require(
      CaptureSampleFactory.videoSample(at: CaptureSampleFactory.videoPTS(frameIndex: 99)))
    session.process(late, with: .video)

    // A second finish must not rewrite the manifest or re-finalize the writer.
    #expect(await finish(session) == nil)
    #expect(try container.readManifest(sessionId).state == .finished)
  }

  // MARK: - The routing seam (this is the point of the chunk)

  @Test func eachReplayKitBufferTypeLandsInItsOwnTrackNotItsPeer() async throws {
    // THE test for this chunk. `capture-core`'s routing switch could have its
    // arms swapped with every gate still green (#839); this one has three arms.
    //
    // Two independent discriminators, because either alone has a blind spot:
    //
    // - Per-type buffer COUNTS (video 12 / mic 4 / app 9) catch a switch that
    //   ignores its type argument, but not a consistent mic <-> app reversal:
    //   that still yields two correctly-durationed tracks.
    // - Each audio input's CONFIGURED SAMPLE RATE (44_100 narration, 22_050
    //   app audio) names which PHYSICAL input received a buffer, because an
    //   output track reports its input's configured rate regardless of the PCM
    //   fed to it (established in `capture-core`). Pairing rate with duration
    //   is what catches the reversal.
    //
    // Swap `.video` with either audio arm and video buffers land in an audio
    // input: the video track disappears and its duration assertion fails.
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    let videoFrames = 12
    let narrationBuffers = 4
    let appAudioBuffers = 9

    try session.start()
    try feedVideo(session, frames: videoFrames)
    try feedAudio(
      session, type: .audioMic, buffers: narrationBuffers, rate: Self.narrationRate)
    try feedAudio(
      session, type: .audioApp, buffers: appAudioBuffers, rate: Self.appAudioRate)
    #expect(try #require(await finish(session)).state == .finished)

    let media = try container.mediaURL(sessionId)
    let counts = try await tracks(media)
    #expect(counts.video == 1)
    #expect(counts.audio == 2)

    let byRate = try await audioTracksByRate(media)
    let narrationSeconds = try #require(byRate[Self.narrationRate])
    let appAudioSeconds = try #require(byRate[Self.appAudioRate])
    #expect(
      abs(
        narrationSeconds
          - CaptureSampleFactory.expectedSeconds(
            bufferCount: narrationBuffers, sampleRate: Self.narrationRate)) < 0.05)
    #expect(
      abs(
        appAudioSeconds
          - CaptureSampleFactory.expectedSeconds(
            bufferCount: appAudioBuffers, sampleRate: Self.appAudioRate)) < 0.05)

    // The video arm: if `.video` were routed to an audio input, the video input
    // would never receive a buffer and AVFoundation would omit the track from
    // the container entirely (the count assertion above), and the surviving
    // audio tracks could not match narration's and app audio's expected
    // durations.
    //
    // Deliberately NOT asserted as `videoFrames / 30`: firing 12 frames with no
    // wall-clock between them saturates VideoToolbox, and dropping under that
    // backpressure is the correct, measured behaviour (capture-core saw 8 of 15
    // dropped in the same shape). What matters here is that real video reached
    // the video input and nothing more than what was fed.
    let videoTracks = try await AVURLAsset(url: media).loadTracks(withMediaType: .video)
    let videoSeconds = CMTimeGetSeconds(try await #require(videoTracks.first).load(.timeRange).duration)
    #expect(videoSeconds > 0)
    #expect(videoSeconds <= Double(videoFrames) / 30 + 0.05)
  }

  @Test func anUnknownBufferTypeIsDroppedWithoutDisturbingTheFile() async throws {
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    try session.start()
    try feedVideo(session, frames: 6)
    if let future = RPSampleBufferType(rawValue: 99) {
      let sample = try #require(CaptureSampleFactory.audioSample(at: .zero))
      session.process(sample, with: future)
    }
    #expect(try #require(await finish(session)).state == .finished)

    let counts = try await tracks(try container.mediaURL(sessionId))
    #expect(counts.video == 1)
    // The unknown buffer must not have been guessed into a named audio track.
    #expect(counts.audio == 0)
  }

  // MARK: - All four track combinations (absent tracks never stall the writer)

  @Test(arguments: [
    ([] as [RPSampleBufferType], 0),
    ([RPSampleBufferType.audioMic], 1),
    ([RPSampleBufferType.audioApp], 1),
    ([RPSampleBufferType.audioMic, .audioApp], 2),
  ])
  func everyTrackCombinationProducesAValidFile(
    types: [RPSampleBufferType], expectedAudioTracks: Int
  ) async throws {
    // Mic off, app silent, both, neither: all four are normal outcomes, and an
    // input that never receives a buffer must never stall finalization.
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    try session.start()
    try feedVideo(session, frames: 10)
    for type in types {
      try feedAudio(
        session, type: type, buffers: 6,
        rate: type == .audioMic ? Self.narrationRate : Self.appAudioRate)
    }
    let manifest = try #require(await finish(session))

    #expect(manifest.state == .finished)
    #expect((manifest.byteCount ?? 0) > 0)
    let counts = try await tracks(try container.mediaURL(sessionId))
    #expect(counts.video == 1)
    #expect(counts.audio == expectedAudioTracks)
  }

  @Test func audioArrivingBeforeTheFirstVideoFrameIsDroppedNotBuffered() async throws {
    // The writer's dimensions come from the first video buffer, so audio that
    // beats it has nowhere to go. It must be dropped and counted, never held -
    // a queue here is retained memory in a 50 MB process.
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    try session.start()
    try feedAudio(session, type: .audioMic, buffers: 3, rate: Self.narrationRate)
    #expect(session.droppedSampleCount() == 3)

    try feedVideo(session, frames: 8)
    try feedAudio(session, type: .audioMic, buffers: 5, rate: Self.narrationRate)
    #expect(try #require(await finish(session)).state == .finished)

    let counts = try await tracks(try container.mediaURL(sessionId))
    #expect(counts.video == 1)
    #expect(counts.audio == 1)
  }

  @Test func videoIsDownscaledToTheSevenTwentyLongEdgeBeforeEncoding() async throws {
    // The memory lever, asserted on the artifact rather than on the settings
    // dictionary: a 1280x960 source must come out of the writer at 720 on its
    // long edge.
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    try session.start()
    for index in 0..<10 {
      let sample = try #require(
        CaptureSampleFactory.videoSample(
          at: CaptureSampleFactory.videoPTS(frameIndex: index), width: 1_280, height: 960))
      session.process(sample, with: .video)
    }
    #expect(try #require(await finish(session)).state == .finished)

    let asset = AVURLAsset(url: try container.mediaURL(sessionId))
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(Int(size.width) == 720)
    #expect(Int(size.height) == 540)
  }

  @Test func aSessionStoppedByTheDurationCapIsRecordedAsCappedNotFinished() async throws {
    // Enforcing a plan-derived ceiling is `cap-enforcement`, a later chunk.
    // What exists here is the hook: the sink already stops admitting samples at
    // `maxDuration`, and this is the one line that maps that to a manifest
    // state the host app can tell apart from a user-initiated stop.
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId, capSeconds: 0.1)

    try session.start()
    // 30 fps synthetic PTS: frame 3 is the first past a 0.1 s cap.
    try feedVideo(session, frames: 8)
    let manifest = try #require(await finish(session))

    #expect(manifest.state == .capped)
    // Capped is a normal end of recording, so the file is still real evidence.
    #expect((manifest.byteCount ?? 0) > 0)
    let counts = try await tracks(try container.mediaURL(sessionId))
    #expect(counts.video == 1)
  }

  @Test func manifestDeclaresWhichAudioTracksActuallyReceivedBuffers() async throws {
    // The host app and the server read track presence off the manifest instead
    // of probing a possibly-truncated `.mov`, so the declaration has to reflect
    // what was really written - not what was merely configured.
    let (container, root) = makeContainer()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionId = UUID().uuidString
    let session = makeSession(container: container, sessionId: sessionId)

    try session.start()
    try feedVideo(session, frames: 6)
    try feedAudio(session, type: .audioApp, buffers: 4, rate: Self.appAudioRate)
    let manifest = try #require(await finish(session))

    #expect(manifest.hasAppAudio)
    #expect(manifest.hasNarration == false)
    #expect(try container.readManifest(sessionId).hasNarration == false)
  }
}
