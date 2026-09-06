import AVFoundation
import Testing

@testable import ShakeToShip

@Suite struct FeedbackRecorderSettingsTests {
  @Test func videoSettingsRequestH264WithScreenContentBitrate() throws {
    let settings = FeedbackRecorderSettings.video(width: 1_179, height: 2_556)

    #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .h264)

    let compression = try #require(
      settings[AVVideoCompressionPropertiesKey] as? [String: Any])
    let bitrate = try #require(compression[AVVideoAverageBitRateKey] as? Int)
    #expect(bitrate >= 4_000_000)
    #expect(bitrate <= 10_000_000)
  }

  @Test func defaultCaptureFitsTheServerUploadLimitWithSafetyMargin() {
    let duration = ShakeToShipConfig.defaultMaxDuration
    let videoBits = duration * Double(FeedbackRecorderSettings.screenContentBitrate)
    let narrationBits = duration * Double(FeedbackRecorderSettings.narrationBitrate)
    let estimatedBytes = (videoBits + narrationBits) / 8

    #expect(
      estimatedBytes * 1.2
        < Double(ShakeToShipConfig.serverUploadLimitBytes))
  }
}
