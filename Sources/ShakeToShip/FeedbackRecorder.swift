import Foundation

public enum FeedbackRecorderError: Error {
  case unavailableOnSimulator
  case alreadyRecording
  case notRecording
  /// AVAssetWriter rejected a required input track (H.264 video / AAC audio).
  case setupFailed
  /// Stop was called before any sample buffer arrived; nothing to finalize.
  case emptyRecording
  /// The asset writer ended in `.failed` (encoder/disk error); the MOV is unusable.
  case writeFailed(Error?)
  /// `RPScreenRecorder` reports recording but ShakeToShip does not own that
  /// session (something else in the process holds ReplayKit). We refuse to
  /// hijack it. Maps to fixed user-facing copy - never the raw ReplayKit error.
  case recorderBusy
  /// ShakeToShip owned a stranded session but resetting it (`stopCapture`)
  /// failed, so a clean start is impossible. Also maps to fixed copy.
  case resetFailed
}

#if os(iOS)
import Foundation

/// Process-global ownership of the shared `RPScreenRecorder`. The recorder is a
/// singleton, so `isRecording == true` does NOT prove ShakeToShip started it -
/// and a session stranded by a suspend/interruption belongs to a PRIOR
/// `FeedbackRecorder` instance (a fresh instance is created per recording), so
/// instance state cannot see it. Ownership is therefore tracked here, across
/// instances, for the whole process. Set true only after OUR `startCapture`
/// confirms; cleared only after a full teardown or a successful reset. If a stop
/// never completes (app suspended mid-capture), it stays true - correctly
/// flagging the leftover session as ours to reset on the next start.
enum FeedbackRecorderOwnership {
  private static let lock = NSLock()
  // Guarded by `lock` on every access, so the unchecked annotation is sound.
  nonisolated(unsafe) private static var owned = false

  static func markOwned() {
    lock.lock(); defer { lock.unlock() }
    owned = true
  }

  static func clearOwned() {
    lock.lock(); defer { lock.unlock() }
    owned = false
  }

  static var isOwned: Bool {
    lock.lock(); defer { lock.unlock() }
    return owned
  }
}
#endif

#if os(iOS)
import AVFoundation
import ReplayKit

/// Device-only in-app screen recorder: ReplayKit `startCapture` video + mic
/// sample buffers written to an `AVAssetWriter` (.mov, H.264 video + AAC audio).
///
/// NOT unit tested - ReplayKit is device-only. Kept thin and isolated from the
/// tested logic (session model, trail, uploader).
public actor FeedbackRecorder {
  /// #943: built lazily, INSIDE actor isolation. The first
  /// `RPScreenRecorder.shared()` in a process is a synchronous XPC handshake
  /// with `replayd`, and a stored-property initializer runs as part of the
  /// non-isolated `init`, i.e. on whatever thread constructs the actor. That
  /// caller is the MainActor shake-to-record start path, so the handshake parked
  /// the main thread in `mach_msg` (Sentry `App Hang Fully Blocked`). Every
  /// `recorder` use below is in an actor-isolated method, so the handshake now
  /// happens on the actor's executor. Actors are reference types, hence the
  /// accessor may populate the cache without being `mutating`.
  private var cachedRecorder: RPScreenRecorder?
  private var recorder: RPScreenRecorder {
    if let cachedRecorder { return cachedRecorder }
    let created = RPScreenRecorder.shared()
    cachedRecorder = created
    return created
  }

  private let maxDuration: TimeInterval
  /// Invoked (on ReplayKit's queue) when the capture handler reports an error,
  /// i.e. the capture was interrupted (call/background). Routed to the modifier
  /// which treats it as a normal stop.
  private let onInterruption: (@Sendable () -> Void)?

  private var writer: AVAssetWriter?
  private var sink: WriterSink?
  private var outputURL: URL?

  public init(maxDuration: TimeInterval = 300, onInterruption: (@Sendable () -> Void)? = nil) {
    self.maxDuration = maxDuration
    self.onInterruption = onInterruption
  }

  /// Starts capturing to `url`. Throws on the simulator, if a required track
  /// cannot be added, or if ReplayKit refuses to start.
  public func start(to url: URL) async throws {
    #if targetEnvironment(simulator)
    print("[ShakeToShip] ReplayKit is non-functional on the simulator; recording is a no-op.")
    throw FeedbackRecorderError.unavailableOnSimulator
    #else
    guard writer == nil else { throw FeedbackRecorderError.alreadyRecording }

    // #472 defensive recovery: a prior capture stranded by a background/scene
    // interruption can leave RPScreenRecorder in the recording state even though
    // OUR writer is nil (state cleared, session not). Starting then surfaces the
    // raw "attempting to start a recording while already in recording state"
    // error. Reset it first so a fresh start always works - but ONLY when the
    // stranded session is ours: `RPScreenRecorder` is process-global, so an
    // `isRecording` we did not start belongs to something else and must never be
    // hijacked. And if the reset itself fails, do NOT proceed onto a dirty
    // recorder; surface a fixed error the caller maps to user-facing copy.
    if recorder.isRecording {
      guard FeedbackRecorderOwnership.isOwned else {
        throw FeedbackRecorderError.recorderBusy
      }
      let didReset = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        recorder.stopCapture { error in cont.resume(returning: error == nil) }
      }
      guard didReset else { throw FeedbackRecorderError.resetFailed }
      FeedbackRecorderOwnership.clearOwned()
    }

    let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
    let bounds = await UIScreen.main.nativeBounds
    let width = Int(bounds.width)
    let height = Int(bounds.height)

    let video = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: FeedbackRecorderSettings.video(width: width, height: height))
    video.expectsMediaDataInRealTime = true

    let audio = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 44_100,
        AVEncoderBitRateKey: 64_000,
      ])
    audio.expectsMediaDataInRealTime = true

    // Fail loudly rather than silently dropping a track and shipping a
    // malformed MOV (AVAssetWriter preconditions: only add when canAdd).
    guard assetWriter.canAdd(video), assetWriter.canAdd(audio) else {
      try? FileManager.default.removeItem(at: url)
      throw FeedbackRecorderError.setupFailed
    }
    assetWriter.add(video)
    assetWriter.add(audio)

    let sink = WriterSink(
      writer: assetWriter, videoInput: video, audioInput: audio, maxDuration: maxDuration)

    recorder.isMicrophoneEnabled = true

    // The handler must NOT capture actor `self`: capturing it makes the
    // closure actor-isolated under Swift 6, and ReplayKit invokes it on its
    // own dispatch queue - the runtime executor check then aborts the process
    // (live device crash: SIGABRT in swift_task_checkIsolatedImpl). Capture
    // only Sendable locals and mark the closure @Sendable/nonisolated.
    let interruption = onInterruption
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      recorder.startCapture(
        handler: { @Sendable sample, bufferType, error in
          // ReplayKit delivers on its own serial queue; append synchronously so
          // sample order is preserved and a stop() cannot interleave with a
          // half-processed buffer (a stray unstructured Task could append after
          // markAsFinished and corrupt the MOV).
          guard error == nil else {
            interruption?()
            return
          }
          sink.append(sample, of: bufferType)
        },
        completionHandler: { error in
          if let error { cont.resume(throwing: error) } else { cont.resume() }
        })
    }

    // Only publish recorder state after ReplayKit confirmed the capture started.
    // Claim process-global ownership here too, so a later start that finds this
    // session stranded (our writer gone, ReplayKit still recording) knows it is
    // ours to reset.
    FeedbackRecorderOwnership.markOwned()
    self.writer = assetWriter
    self.sink = sink
    self.outputURL = url
    #endif
  }

  /// Finalizes the recording and returns the output file URL. Throws
  /// `.emptyRecording` if no sample ever arrived (partial file removed) and
  /// `.writeFailed` if the writer ended in `.failed` (caller must discard).
  public func stop() async throws -> URL {
    #if targetEnvironment(simulator)
    throw FeedbackRecorderError.notRecording
    #else
    guard let writer, let sink, let url = outputURL else {
      throw FeedbackRecorderError.notRecording
    }
    // #472 NEW-1: capture whether ReplayKit actually stopped. A discarded stop
    // error can leave the shared recorder still recording; clearing ownership
    // then would misclassify OUR still-live session as external on the next
    // start (which would refuse to reset it). Gate the ownership clear on this.
    let stopSucceeded = await stopUnderlyingCapture()
    // Quiesce the append path under its lock: once this returns no further
    // sample append can touch the inputs, so markAsFinished/finishWriting run
    // on a drained writer.
    let didWrite = sink.quiesce()

    guard didWrite else {
      // Writer never called startWriting; finishWriting would violate its
      // preconditions. Cancel, drop the partial file, surface empty outcome.
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      finishTeardown(stopSucceeded: stopSucceeded)
      throw FeedbackRecorderError.emptyRecording
    }

    sink.markFinished()
    if writer.status == .writing {
      await writer.finishWriting()
    }
    let status = writer.status
    let error = writer.error
    finishTeardown(stopSucceeded: stopSucceeded)
    if status == .failed {
      try? FileManager.default.removeItem(at: url)
      throw FeedbackRecorderError.writeFailed(error)
    }
    return url
    #endif
  }

  /// Stops the underlying ReplayKit capture if running and reports whether it is
  /// confirmed stopped. Retries once on error before giving up. NOTE: the
  /// completion closures capture ONLY `cont` (never `self`/`recorder`) - a
  /// closure that captures the actor becomes actor-isolated and ReplayKit, which
  /// invokes it on its own queue, would trip the runtime isolation check.
  private func stopUnderlyingCapture() async -> Bool {
    guard recorder.isRecording else { return true }
    let stopped = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      recorder.stopCapture { error in cont.resume(returning: error == nil) }
    }
    if stopped { return true }
    // One explicit retry; if it still errors we retain ownership so the next
    // start() treats the still-live session as our stranded capture to reset.
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
      recorder.stopCapture { error in cont.resume(returning: error == nil) }
    }
  }

  /// Clears @State teardown and, only when ReplayKit is confirmed stopped,
  /// releases process-global ownership. On a failed stop we RETAIN ownership so
  /// the leftover session is treated as ours to reset on the next start.
  private func finishTeardown(stopSucceeded: Bool) {
    reset()
    if stopSucceeded {
      FeedbackRecorderOwnership.clearOwned()
    }
  }

  private func reset() {
    writer = nil
    sink = nil
    outputURL = nil
  }
}

extension FeedbackRecorder: FeedbackCapture {}

/// Serial, lock-guarded bridge between ReplayKit's delivery queue and the
/// `AVAssetWriter`. All writer/input mutation happens here under `lock`, so the
/// actor's `stop()` can quiesce it and then finalize without racing an append.
private final class WriterSink: @unchecked Sendable {
  private let lock = NSLock()
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let audioInput: AVAssetWriterInput
  private let maxDuration: TimeInterval

  private var startPTS: CMTime?
  private var started = false
  private var reachedCap = false
  private var quiesced = false

  init(
    writer: AVAssetWriter, videoInput: AVAssetWriterInput,
    audioInput: AVAssetWriterInput, maxDuration: TimeInterval
  ) {
    self.writer = writer
    self.videoInput = videoInput
    self.audioInput = audioInput
    self.maxDuration = maxDuration
  }

  /// Called synchronously on ReplayKit's queue for each sample buffer.
  func append(_ sample: CMSampleBuffer, of type: RPSampleBufferType) {
    lock.lock()
    defer { lock.unlock() }
    guard !quiesced, CMSampleBufferDataIsReady(sample) else { return }

    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    if !started {
      // startWriting returns false on failure (status flips to .failed).
      guard writer.startWriting() else { return }
      writer.startSession(atSourceTime: pts)
      startPTS = pts
      started = true
    }
    // Hard cap: stop feeding samples once maxDuration elapses; behaves like a
    // normal stop (the modifier's timer performs the finalize).
    if let start = startPTS {
      let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, start))
      if elapsed >= maxDuration { reachedCap = true }
    }
    guard !reachedCap, writer.status == .writing else { return }

    switch type {
    case .video:
      if videoInput.isReadyForMoreMediaData { videoInput.append(sample) }
    case .audioMic:
      if audioInput.isReadyForMoreMediaData { audioInput.append(sample) }
    default:
      break
    }
  }

  /// Blocks further appends and reports whether any sample was ever written.
  func quiesce() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    quiesced = true
    return started
  }

  /// Marks both inputs finished. Call only after `quiesce()` returned true.
  func markFinished() {
    lock.lock()
    defer { lock.unlock() }
    videoInput.markAsFinished()
    audioInput.markAsFinished()
  }
}
#endif
