import AVFoundation
import CoreMedia
import Foundation

/// Builds REAL `CMSampleBuffer`s so the sink is exercised against a real
/// `AVAssetWriter` producing a real file. Nothing here is a stand-in for the
/// code under test - these are the same buffer shapes ReplayKit delivers.
enum CaptureSampleFactory {
  static let audioSampleRate: Double = 44_100
  static let audioFramesPerBuffer = 1_024

  static func videoSample(at pts: CMTime, width: Int = 320, height: Int = 240) -> CMSampleBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: CFDictionary =
      [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      ] as CFDictionary
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        == kCVReturnSuccess,
      let pixelBuffer
    else { return nil }

    var format: CMFormatDescription?
    guard
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        == noErr,
      let format
    else { return nil }

    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts,
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr
    else { return nil }
    return sample
  }

  /// Mono 16-bit LPCM silence - exactly what ReplayKit hands over, which the
  /// AAC-configured writer input then encodes.
  static func audioSample(at pts: CMTime, frames: Int = audioFramesPerBuffer) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: audioSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0)

    var format: CMFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        == noErr,
      let format
    else { return nil }

    let byteCount = frames * 2
    var blockBuffer: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer) == noErr,
      let blockBuffer,
      CMBlockBufferFillDataBytes(
        with: 0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount) == noErr
    else { return nil }

    var sample: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
        sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
        sampleBufferOut: &sample) == noErr
    else { return nil }
    return sample
  }

  static func audioPTS(bufferIndex: Int) -> CMTime {
    CMTime(
      value: CMTimeValue(bufferIndex * audioFramesPerBuffer), timescale: CMTimeScale(audioSampleRate)
    )
  }

  static func videoPTS(frameIndex: Int) -> CMTime {
    CMTime(value: CMTimeValue(frameIndex), timescale: 30)
  }

  static func videoInput(width: Int = 320, height: Int = 240) -> AVAssetWriterInput {
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ])
    input.expectsMediaDataInRealTime = true
    return input
  }

  /// `sampleRate` defaults to `audioSampleRate` so every existing call site
  /// (and the PCM shape `audioSample(at:)` produces) is unaffected. Pass a
  /// distinct value to give two inputs a file-observable, encoder-preserved
  /// marker of which one actually received buffers - see
  /// `swappedTrackKeysAreCaughtByTheSurvivingTracksConfiguredSampleRate` in
  /// CaptureWriterSinkTests.
  static func audioInput(sampleRate: Double = audioSampleRate) -> AVAssetWriterInput {
    let input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: sampleRate,
        AVEncoderBitRateKey: 64_000,
      ])
    input.expectsMediaDataInRealTime = true
    return input
  }

  static func outputURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("sink-\(UUID().uuidString).mov")
  }
}
