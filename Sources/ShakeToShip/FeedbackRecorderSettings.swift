import AVFoundation

enum FeedbackRecorderSettings {
  static let screenContentBitrate = 6_000_000
  static let narrationBitrate = 64_000

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
