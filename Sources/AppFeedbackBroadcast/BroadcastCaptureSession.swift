import AVFoundation
import AppFeedbackCapture
import CoreMedia
import Foundation
import ReplayKit

public enum BroadcastCaptureSessionError: Error, Equatable, Sendable {
  /// The App Group container could not be resolved. Without it there is nowhere
  /// the host app can read the recording from, so the broadcast is failed
  /// immediately rather than recorded into a directory nobody will look in.
  case containerUnavailable
  /// `AppFeedbackHostBundleId` is missing from the extension's Info.plist.
  case missingConfiguration
  /// The session directory or its `.recording` manifest could not be written.
  case sessionUnavailable(String)
}

/// One broadcast recording, from `broadcastStarted` to `broadcastFinished`.
///
/// This is everything `FeedbackBroadcastSampleHandler` does, minus ReplayKit's
/// process lifecycle - which is the point: the handler is a three-method shim
/// over this type, and this type is exercised against a real `AVAssetWriter`
/// and a real container in the test suite.
///
/// Concurrency: ReplayKit delivers sample buffers on its own serial queue while
/// `finish()` can be called from another, so mutable state is guarded by
/// `lock`. The lock is deliberately NOT held across `finishWriting` - that
/// would block the delivery queue for the length of the finalize; the session
/// leaves the recording state under the lock first, after which `process` is a
/// no-op and cannot touch the writer.
///
/// Memory: nothing here retains a sample buffer past the call that delivered
/// it. Buffers with nowhere to go (before the writer exists, an unknown type)
/// are counted and dropped, never queued - the process is killed at 50 MB.
public final class BroadcastCaptureSession: @unchecked Sendable {
  private enum State {
    case idle
    case recording
    case finished
  }

  private let lock = NSLock()
  private let container: BroadcastContainer
  private let config: FeedbackBroadcastConfiguration
  private let startedAt: Date
  private let narrationSampleRate: Double
  private let appAudioSampleRate: Double

  public let sessionId: String

  private var state: State = .idle
  private var writer: AVAssetWriter?
  private var sink: CaptureWriterSink?
  /// Tracks that actually received a sample, as opposed to tracks that merely
  /// had an input configured. This is what the manifest declares.
  private var observedAudioTracks: Set<CaptureAudioTrack> = []
  private var firstPTS: CMTime?
  private var lastPTS: CMTime?
  /// Buffers refused before the sink existed, or of a type this build does not
  /// recognise. Added to the sink's own count.
  private var preSinkDrops = 0

  /// - Parameters:
  ///   - narrationSampleRate: Output sample rate for the narration track.
  ///   - appAudioSampleRate: Output sample rate for the app-audio track.
  ///
  ///   The two audio tracks are encoded independently, so their rates are
  ///   independent too; both default to 44.1 kHz, which is what ReplayKit
  ///   delivers. They are settable because that independence is also the only
  ///   file-observable marker of WHICH physical input a buffer reached - see
  ///   `BroadcastCaptureSessionTests.eachReplayKitBufferTypeLandsInItsOwnTrackNotItsPeer`.
  public init(
    container: BroadcastContainer,
    sessionId: String = UUID().uuidString,
    config: FeedbackBroadcastConfiguration,
    startedAt: Date = Date(),
    narrationSampleRate: Double = 44_100,
    appAudioSampleRate: Double = 44_100
  ) {
    self.container = container
    self.sessionId = sessionId
    self.config = config
    self.startedAt = startedAt
    self.narrationSampleRate = narrationSampleRate
    self.appAudioSampleRate = appAudioSampleRate
  }

  /// Publishes the session directory and a `.recording` manifest.
  ///
  /// Deliberately does NOT create the writer: the frame size is only known once
  /// the first video buffer arrives (an extension cannot ask `UIScreen`), and
  /// the manifest has to exist before any of that so a process killed a
  /// millisecond later still leaves something the host app's sweep can find.
  @discardableResult
  public func start() throws -> BroadcastManifest {
    lock.lock()
    defer { lock.unlock() }
    guard state == .idle else { throw BroadcastCaptureSessionError.sessionUnavailable(sessionId) }
    let manifest = try container.mint(
      sessionId: sessionId,
      startedAt: startedAt,
      appBundleId: config.hostBundleId,
      sdkVersion: config.sdkVersion,
      // Nothing has been observed yet; `finish` corrects both from what the
      // writer actually accepted.
      hasNarration: false,
      hasAppAudio: false,
      capSeconds: config.capSeconds)
    state = .recording
    return manifest
  }

  /// Routes one ReplayKit sample buffer. Called on ReplayKit's delivery queue.
  public func process(_ sample: CMSampleBuffer, with type: RPSampleBufferType) {
    lock.lock()
    defer { lock.unlock() }
    guard state == .recording else { return }
    guard let route = BroadcastSampleRoute(bufferType: type) else {
      preSinkDrops += 1
      return
    }
    // The writer's dimensions come from the first video buffer, so audio that
    // arrives before it has nowhere to land. Dropped, not held.
    if sink == nil {
      guard route == .video, let started = makeWriter(firstVideo: sample) else {
        preSinkDrops += 1
        return
      }
      writer = started.writer
      sink = started.sink
    }
    guard let sink else { return }

    // The sink drops rather than queues when an input is not ready, so
    // "appended" is the difference in its drop counter - which is also what
    // makes `observedAudioTracks` mean "this track has real samples in it"
    // rather than "a buffer was offered for it".
    let droppedBefore = sink.droppedSampleCount()
    route.append(sample, to: sink)
    guard sink.droppedSampleCount() == droppedBefore else { return }

    if case .audio(let track) = route {
      observedAudioTracks.insert(track)
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    if firstPTS == nil { firstPTS = pts }
    lastPTS = pts
  }

  /// Finalizes the file and rewrites the manifest in a terminal state.
  ///
  /// Returns `nil` if the session was never started or has already finished -
  /// ReplayKit can call `broadcastFinished` more than once, and a second
  /// finalize must not rewrite a manifest the host app may already be acting
  /// on.
  ///
  /// - Parameter timeout: Bound on the `finishWriting` wait.
  ///   `broadcastFinished` gets very little time before the process is torn
  ///   down, so the wait is bounded and a session that overruns it is recorded
  ///   as `.aborted` (its partial file is still evidence) rather than claimed
  ///   as `.finished`.
  @discardableResult
  public func finish(timeout: TimeInterval = 4) -> BroadcastManifest? {
    lock.lock()
    guard state == .recording else {
      lock.unlock()
      return nil
    }
    state = .finished
    let sink = self.sink
    let writer = self.writer
    let observed = observedAudioTracks
    let duration = measuredDuration()
    // Released before the finalize: `process` is already a no-op now that the
    // state has moved, so holding it across `finishWriting` would only block
    // ReplayKit's delivery queue.
    lock.unlock()

    guard let sink, let writer, sink.quiesce() else {
      // Nothing was ever written. `finishWriting` would violate its own
      // preconditions, so cancel and drop the empty file.
      writer?.cancelWriting()
      if let media = try? container.mediaURL(sessionId) {
        try? FileManager.default.removeItem(at: media)
      }
      return try? container.finalize(
        sessionId: sessionId, state: .aborted, durationSeconds: 0,
        observedAudioTracks: observed)
    }

    sink.markFinished()
    let completed = writeOut(writer, timeout: timeout)
    // A timed-out or failed write leaves a file that may have no moov atom.
    // It is still handed to the host app - a truncated recording of the bug is
    // worth more than a tidy empty directory - but it is not called `.finished`.
    let terminalState: BroadcastManifest.State =
      completed && writer.status == .completed
      ? (sink.hasReachedCap() ? .capped : .finished)
      : .aborted
    return try? container.finalize(
      sessionId: sessionId, state: terminalState, durationSeconds: duration,
      observedAudioTracks: observed)
  }

  /// Buffers dropped rather than queued: the sink's own count (input not ready,
  /// no configured destination) plus those refused before the writer existed.
  /// Non-zero is normal under encoder backpressure.
  public func droppedSampleCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return preSinkDrops + (sink?.droppedSampleCount() ?? 0)
  }

  /// Media seconds actually admitted, derived from sample timestamps. Never
  /// from the finished asset: opening it would cost memory this process does
  /// not have.
  private func measuredDuration() -> Double {
    guard let firstPTS, let lastPTS else { return 0 }
    let seconds = CMTimeGetSeconds(CMTimeSubtract(lastPTS, firstPTS))
    return seconds.isFinite && seconds > 0 ? seconds : 0
  }

  /// Bounded, synchronous `finishWriting`. `broadcastFinished` is synchronous
  /// and the process is torn down when it returns, so there is nowhere to defer
  /// this to.
  private func writeOut(_ writer: AVAssetWriter, timeout: TimeInterval) -> Bool {
    guard writer.status == .writing else { return writer.status == .completed }
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    return semaphore.wait(timeout: .now() + timeout) == .success
  }

  /// Builds the writer from the first video buffer's dimensions, returning it
  /// for the caller to install (this is pure construction; it mutates nothing).
  ///
  /// Both audio inputs are configured up front, before anyone can know whether
  /// the mic is live or the app is silent. An input that never receives a
  /// buffer is omitted from the finished file by AVFoundation and does not
  /// stall the others.
  private func makeWriter(
    firstVideo: CMSampleBuffer
  ) -> (writer: AVAssetWriter, sink: CaptureWriterSink)? {
    guard let size = BroadcastVideoSettings.sourceDimensions(of: firstVideo),
      let videoSettings = BroadcastVideoSettings.outputSettings(
        sourceWidth: size.width, sourceHeight: size.height),
      let url = try? container.mediaURL(sessionId),
      let writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
    else { return nil }

    let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    video.expectsMediaDataInRealTime = true
    guard writer.canAdd(video) else { return nil }
    writer.add(video)

    var audioInputs: [CaptureAudioTrack: AVAssetWriterInput] = [:]
    for (track, rate) in [
      (CaptureAudioTrack.narration, narrationSampleRate),
      (CaptureAudioTrack.appAudio, appAudioSampleRate),
    ] {
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVNumberOfChannelsKey: 1,
          AVSampleRateKey: rate,
          AVEncoderBitRateKey: 64_000,
        ])
      input.expectsMediaDataInRealTime = true
      // A track that cannot be added is skipped rather than failing the whole
      // recording: video plus one audio track is still evidence. The sink drops
      // buffers for an unconfigured track without starting the writer.
      guard writer.canAdd(input) else { continue }
      writer.add(input)
      audioInputs[track] = input
    }

    return (
      writer,
      CaptureWriterSink(
        writer: writer, videoInput: video, audioInputs: audioInputs,
        maxDuration: config.capSeconds)
    )
  }
}
