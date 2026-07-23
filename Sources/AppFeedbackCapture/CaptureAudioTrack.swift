import Foundation

/// The named audio tracks a capture can carry.
///
/// They are separate `AVAssetWriterInput`s in one file and are NEVER mixed:
/// mixing means resampling and summing PCM inside a broadcast extension capped
/// at 50 MB, while two inputs just append. Both are optional at runtime - a
/// muted mic or a silent app simply produces no buffers for that track.
public enum CaptureAudioTrack: String, Sendable, CaseIterable, Hashable {
  /// The person talking over the recording (microphone).
  case narration
  /// What the device itself is playing (app audio).
  case appAudio
}
