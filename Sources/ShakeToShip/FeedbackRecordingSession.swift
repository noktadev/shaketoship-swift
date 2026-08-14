import Foundation

/// The device capture boundary. Session lifecycle tests replace only this leaf;
/// the production implementation is `FeedbackRecorder`.
protocol FeedbackCapture: Sendable {
  func start(to url: URL) async throws
  func stop() async throws -> URL
}

struct FeedbackRecordingSegment: Codable, Sendable, Equatable {
  let file: String

  init(file: String) {
    self.file = file
  }
}

enum FeedbackRecordingSessionState: Sendable, Equatable {
  case ready
  case recording
  case paused
  case finalized
}

enum FeedbackRecordingSessionError: Error {
  case invalidTransition
}

/// Keeps one logical feedback session open while ReplayKit capture is stopped
/// and restarted across app background/foreground transitions.
actor FeedbackRecordingSession {
  private(set) var state: FeedbackRecordingSessionState = .ready

  private let directory: URL
  private let capture: any FeedbackCapture
  private var segments: [FeedbackRecordingSegment] = []

  init(directory: URL, capture: any FeedbackCapture) {
    self.directory = directory
    self.capture = capture
  }

  func start() async throws {
    guard state == .ready else { throw FeedbackRecordingSessionError.invalidTransition }
    try await startSegment()
  }

  func pause() async throws {
    guard state == .recording else { throw FeedbackRecordingSessionError.invalidTransition }
    do {
      try await finishCurrentSegment()
    } catch {
      // The underlying capture already attempted (and failed) to close this
      // segment - fold into `.paused` anyway so a later `finalize()` never
      // re-invokes `capture.stop()` for it. A second stop call on an
      // already-stopped capture throws `.notRecording`, which previously
      // propagated out of `finalize()` uncaught and let the caller nuke the
      // whole session dir, discarding earlier valid segments (#669 MUST-FIX 3).
      state = .paused
      throw error
    }
    state = .paused
  }

  func resume() async throws {
    guard state == .paused else { throw FeedbackRecordingSessionError.invalidTransition }
    try await startSegment()
  }

  /// Read-only snapshot of segments closed so far - does not mutate state.
  /// Used to persist a pause-durability sidecar without finalizing (#669).
  func snapshotSegments() -> [FeedbackRecordingSegment] {
    segments
  }

  func finalize() async throws -> [FeedbackRecordingSegment] {
    switch state {
    case .recording:
      try await finishCurrentSegment()
    case .paused:
      break
    case .ready, .finalized:
      throw FeedbackRecordingSessionError.invalidTransition
    }
    state = .finalized
    return segments
  }

  private func startSegment() async throws {
    let name =
      segments.isEmpty
      ? FeedbackAttachmentNaming.recordingFile
      : String(format: "recording-%03d.mov", segments.count + 1)
    try await capture.start(to: directory.appendingPathComponent(name))
    state = .recording
  }

  private func finishCurrentSegment() async throws {
    do {
      let url = try await capture.stop()
      segments.append(FeedbackRecordingSegment(file: url.lastPathComponent))
    } catch FeedbackRecorderError.emptyRecording {
      // An immediate background/stop can close a segment before ReplayKit emits
      // its first sample. It contributes no file but does not invalidate older
      // segments in the same logical session.
    }
  }
}
