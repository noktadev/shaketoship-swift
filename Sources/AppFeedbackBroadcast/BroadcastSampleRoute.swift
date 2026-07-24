import AppFeedbackCapture
import CoreMedia
import Foundation
import ReplayKit

/// Where one `RPBroadcastSampleHandler` sample buffer belongs in the file.
///
/// This is the boundary the design puts ReplayKit's enum behind:
/// `AppFeedbackCapture` must never link ReplayKit (it has to stay linkable from
/// the 50 MB extension), so `RPSampleBufferType` is translated here, on this
/// side of it, and `CaptureWriterSink` only ever sees "video" or "audio on
/// track X".
///
/// It is a value rather than a `switch` inlined into `processSampleBuffer`
/// specifically so the mapping can be asserted directly - see
/// `BroadcastSampleRouteTests` for why (`capture-core`'s inlined two-arm switch
/// could have its arms swapped with every gate still green, #839).
public enum BroadcastSampleRoute: Equatable, Sendable {
  case video
  case audio(CaptureAudioTrack)

  /// `nil` for a buffer type this build does not recognise. `RPSampleBufferType`
  /// is an `NS_ENUM` bridged as a `RawRepresentable`, so a future OS can hand
  /// over a value that is none of the three known cases.
  public init?(bufferType: RPSampleBufferType) {
    switch bufferType {
    case .video:
      self = .video
    // The mic is the person talking over the recording; the server transcribes
    // this track as the reviewer's commentary.
    case .audioMic:
      self = .audio(.narration)
    // What the device itself was playing. Kept as its own track and never
    // mixed into narration: mixing would mean resampling and summing PCM
    // inside the memory-capped extension, and would destroy the distinction
    // the analysis pipeline depends on.
    case .audioApp:
      self = .audio(.appAudio)
    @unknown default:
      return nil
    }
  }

  /// Hands `sample` to the one input this route names. Nothing retains the
  /// buffer past this call: the sink either appends it synchronously or drops
  /// it, and never queues.
  public func append(_ sample: CMSampleBuffer, to sink: CaptureWriterSink) {
    switch self {
    case .video:
      sink.appendVideo(sample)
    case .audio(let track):
      sink.appendAudio(sample, track: track)
    }
  }
}
