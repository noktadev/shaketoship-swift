import AVFoundation
import CoreMedia
import Foundation

/// Video encoding shape for a broadcast capture.
///
/// The broadcast upload extension runs in a process Jetsam kills at 50 MB, and
/// video is where practically all of that budget goes. Two decisions live here,
/// both of them about not spending it:
///
/// 1. **Downscale to 720 px on the long edge.** A native iPad frame is ~4x the
///    pixels of a 720-long-edge one through the encoder.
/// 2. **Let `AVAssetWriter` do the scaling** via `AVVideoScalingModeKey`, rather
///    than resizing frames ourselves. A manual downscale means a second
///    `CVPixelBuffer` allocated per frame, which is exactly the allocation
///    pattern the cap punishes.
public enum BroadcastVideoSettings {
  /// Long-edge target in pixels. Anything already under it is left alone.
  public static let longEdge = 720

  /// Screen content at 720-long-edge. Screen recordings are mostly flat colour
  /// and text, so they compress far better than camera footage at the same
  /// resolution; the in-app path's 6 Mbps is sized for native resolution.
  static let bitrate = 2_500_000

  /// Scales `width` x `height` down so the longer axis is at most `longEdge`,
  /// preserving aspect ratio.
  ///
  /// Returns `nil` for a non-positive input rather than producing a size
  /// `AVAssetWriter` would reject - the caller drops that buffer instead.
  /// Both axes come back even (H.264 4:2:0 subsamples both) and never below 2,
  /// so an extreme aspect ratio cannot collapse an axis to zero.
  public static func scaledDimensions(
    width: Int, height: Int, longEdge: Int = longEdge
  ) -> (width: Int, height: Int)? {
    guard width > 0, height > 0, longEdge > 0 else { return nil }
    let source = max(width, height)
    // Never upscale: inventing pixels costs encoder bandwidth in the one
    // process that cannot pay for it, and adds nothing to the evidence.
    let scale = source > longEdge ? Double(longEdge) / Double(source) : 1
    return (evened(Double(width) * scale), evened(Double(height) * scale))
  }

  /// `AVAssetWriterInput` output settings for a source frame of the given size,
  /// or `nil` if that size is unusable.
  public static func outputSettings(sourceWidth: Int, sourceHeight: Int) -> [String: Any]? {
    guard let scaled = scaledDimensions(width: sourceWidth, height: sourceHeight) else {
      return nil
    }
    return [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: scaled.width,
      AVVideoHeightKey: scaled.height,
      // The downscale itself: the writer resizes during encode, so no frame is
      // ever copied into a buffer of our own.
      AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
      ],
    ]
  }

  /// Pixel dimensions of a video sample buffer, or `nil` if it carries no video
  /// format description (an audio buffer, or a buffer whose format was
  /// stripped).
  static func sourceDimensions(of sample: CMSampleBuffer) -> (width: Int, height: Int)? {
    guard let format = CMSampleBufferGetFormatDescription(sample),
      CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video
    else { return nil }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    return (Int(dimensions.width), Int(dimensions.height))
  }

  private static func evened(_ value: Double) -> Int {
    max(2, Int((value / 2).rounded()) * 2)
  }
}
