import AVFoundation

enum FeedbackRecorderSettings {
  private static let screenContentBitrate = 6_000_000

  static func video(width: Int, height: Int) -> [String: Any] {
    [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: screenContentBitrate,
      ],
    ]
  }
}
