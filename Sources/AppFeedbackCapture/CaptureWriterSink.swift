import AVFoundation
import CoreMedia
import Foundation

/// Serial, lock-guarded bridge between a sample-buffer producer and an
/// `AVAssetWriter`. All writer/input mutation happens here under `lock`, so the
/// owner's stop path can `quiesce()` and then finalize without racing an append.
///
/// Extracted from `FeedbackRecorder` unchanged in behaviour, then widened on one
/// axis: the audio side is now a map of named tracks instead of a single input.
/// `RPScreenRecorder.startCapture` and
/// `RPBroadcastSampleHandler.processSampleBuffer` deliver the same buffer types,
/// so the broadcast path inherits this proven pipeline instead of growing a
/// second one. This type deliberately does not import ReplayKit: callers map
/// their own buffer-type enum onto `appendVideo` / `appendAudio`, which keeps it
/// linkable from an app extension and testable off-device.
///
/// Every audio track is optional at runtime. A configured input that never
/// receives a buffer is simply omitted from the finished file (AVFoundation
/// drops tracks with zero samples); it never stalls the writer.
public final class CaptureWriterSink: @unchecked Sendable {
  private let lock = NSLock()
  private let writer: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let audioInputs: [CaptureAudioTrack: AVAssetWriterInput]
  private let maxDuration: TimeInterval

  private var startPTS: CMTime?
  private var started = false
  private var reachedCap = false
  private var quiesced = false
  private var dropped = 0

  public init(
    writer: AVAssetWriter,
    videoInput: AVAssetWriterInput,
    audioInputs: [CaptureAudioTrack: AVAssetWriterInput],
    maxDuration: TimeInterval
  ) {
    self.writer = writer
    self.videoInput = videoInput
    self.audioInputs = audioInputs
    self.maxDuration = maxDuration
  }

  /// Called synchronously on the producer's queue for each video sample buffer.
  public func appendVideo(_ sample: CMSampleBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard admit(sample) else { return }
    append(sample, to: videoInput)
  }

  /// Called synchronously on the producer's queue for each audio sample buffer.
  /// A buffer for a track with no configured input is dropped, not held.
  public func appendAudio(_ sample: CMSampleBuffer, track: CaptureAudioTrack) {
    lock.lock()
    defer { lock.unlock() }
    // Look up the destination BEFORE admit(): admit() starts the writing
    // session and latches `started` as a side effect, so a buffer with no
    // configured destination must never reach it. Otherwise an unmapped
    // track's buffer (e.g. `.appAudio` arriving with only `.narration`
    // configured) would start the session, quiesce() would then report
    // "something was written", and the caller would finalize a file with
    // zero real samples in it.
    guard let input = audioInputs[track] else {
      dropped += 1
      return
    }
    guard admit(sample) else { return }
    append(sample, to: input)
  }

  /// Blocks further appends and reports whether any sample was ever written.
  /// A false result means the writer never started, so `finishWriting` would
  /// violate its preconditions and the caller must cancel instead.
  public func quiesce() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    quiesced = true
    return started
  }

  /// Marks the video input and every configured audio input finished.
  /// Call only after `quiesce()` returned true.
  public func markFinished() {
    lock.lock()
    defer { lock.unlock() }
    videoInput.markAsFinished()
    for input in audioInputs.values { input.markAsFinished() }
  }

  /// Buffers refused because their destination input was not ready (or does not
  /// exist). Non-zero is normal under encoder backpressure; it is exposed so the
  /// memory discipline is observable rather than assumed.
  public func droppedSampleCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return dropped
  }

  /// True once `maxDuration` of media has elapsed. The owner treats this like a
  /// normal stop and records manifest state `.capped`.
  public func hasReachedCap() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return reachedCap
  }

  /// Shared gate: starts the writing session on the first ready buffer of any
  /// kind, then enforces the duration cap. Caller must hold `lock`.
  private func admit(_ sample: CMSampleBuffer) -> Bool {
    guard !quiesced, CMSampleBufferDataIsReady(sample) else { return false }

    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    if !started {
      // startWriting returns false on failure (status flips to .failed).
      guard writer.startWriting() else { return false }
      writer.startSession(atSourceTime: pts)
      startPTS = pts
      started = true
    }
    // Hard cap: stop feeding samples once maxDuration elapses; behaves like a
    // normal stop (the owner's timer performs the finalize).
    if let start = startPTS {
      let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, start))
      if elapsed >= maxDuration { reachedCap = true }
    }
    return !reachedCap && writer.status == .writing
  }

  /// Appends only when the input can take it right now. Never queue: a backlog
  /// held here is retained memory, and the broadcast extension it will run in
  /// gets killed at 50 MB. Dropping a frame degrades the recording; queueing
  /// ends it.
  private func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) {
    guard input.isReadyForMoreMediaData else {
      dropped += 1
      return
    }
    input.append(sample)
  }
}
