import AVFoundation
import Foundation
import Testing

@testable import AppFeedbackBroadcast

/// The downscale is the single biggest lever on the extension's 50 MB budget,
/// and it is pure arithmetic - so it is tested as arithmetic here, and its
/// effect on a real file is asserted in `BroadcastCaptureSessionTests`.
@Suite struct BroadcastVideoSettingsTests {
  @Test func scalesAPortraitPhoneToSevenTwentyOnTheLongEdge() {
    // iPhone 15 Pro native bounds.
    let scaled = BroadcastVideoSettings.scaledDimensions(width: 1_179, height: 2_556)
    #expect(scaled?.height == 720)
    // 1179 * (720/2556) = 332.1 -> 332, the nearest even value.
    #expect(scaled?.width == 332)
  }

  @Test func scalesALandscapeIPadToSevenTwentyOnTheLongEdge() {
    // iPad Pro 12.9 landscape - the device the memory cap bites hardest on.
    let scaled = BroadcastVideoSettings.scaledDimensions(width: 2_732, height: 2_048)
    #expect(scaled?.width == 720)
    // 2048 * (720/2732) = 539.7 -> 540.
    #expect(scaled?.height == 540)
  }

  @Test func neverUpscalesASourceAlreadyUnderTheLongEdge() {
    // Upscaling would spend encoder bandwidth inventing pixels that were never
    // captured, inside the process that can least afford it.
    let scaled = BroadcastVideoSettings.scaledDimensions(width: 320, height: 240)
    #expect(scaled?.width == 320)
    #expect(scaled?.height == 240)
  }

  @Test func alwaysProducesEvenDimensions() {
    // H.264 4:2:0 chroma subsampling halves both axes; an odd dimension makes
    // the encoder pad, and some decoders then render a green edge column.
    for height in 1_001...1_040 {
      let scaled = BroadcastVideoSettings.scaledDimensions(width: 733, height: height)
      let width = try? #require(scaled?.width)
      let scaledHeight = try? #require(scaled?.height)
      #expect((width ?? 1) % 2 == 0)
      #expect((scaledHeight ?? 1) % 2 == 0)
    }
  }

  @Test func neverCollapsesAnExtremeAspectRatioToZero() {
    // A zero-width input is rejected by AVAssetWriter, so the thin axis floors
    // at 2 (even) rather than rounding down to nothing.
    let scaled = BroadcastVideoSettings.scaledDimensions(width: 4, height: 4_000)
    #expect(scaled?.height == 720)
    #expect(scaled?.width == 2)
  }

  @Test func rejectsNonPositiveSourceDimensions() {
    // Comes from CMVideoFormatDescriptionGetDimensions on a real buffer, so
    // this should never happen - but returning nil lets the caller drop the
    // buffer instead of constructing a writer input AVFoundation will reject.
    #expect(BroadcastVideoSettings.scaledDimensions(width: 0, height: 1_280) == nil)
    #expect(BroadcastVideoSettings.scaledDimensions(width: 720, height: -1) == nil)
  }

  @Test func outputSettingsAskForHardwareH264AtTheScaledSize() {
    let settings = try? #require(
      BroadcastVideoSettings.outputSettings(sourceWidth: 1_179, sourceHeight: 2_556))
    #expect(settings?[AVVideoWidthKey] as? Int == 332)
    #expect(settings?[AVVideoHeightKey] as? Int == 720)
    #expect(settings?[AVVideoCodecKey] as? AVVideoCodecType == .h264)
    // AVAssetWriter does the downscale itself during encode. Doing it here
    // instead would mean allocating a second CVPixelBuffer per frame in a
    // 50 MB process.
    #expect(settings?[AVVideoScalingModeKey] as? String == AVVideoScalingModeResizeAspect)
  }
}
