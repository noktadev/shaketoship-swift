@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import ShakeToShip

@Suite struct FeedbackVideoCompressionIntegrationTests {
  @Test func realExportPreservesSyntheticVideoAudioDurationAndOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sts-compression-integration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try await makeRecording(in: directory)
    let originalBytes = try Data(contentsOf: source)
    let destination = directory.appendingPathComponent("compressed.mov")

    try await AVFeedbackVideoCompressor().compress(source: source, destination: destination,
      maximumBytes: FeedbackVideoRecovery.maximumBytes)

    #expect(try Data(contentsOf: source) == originalBytes)
    let input = AVURLAsset(url: source)
    let output = AVURLAsset(url: destination)
    let before = try await input.load(.duration).seconds
    let after = try await output.load(.duration).seconds
    #expect(abs(before - 1) < 0.05)
    #expect(abs(after - before) < 0.05)
    let videoTracks = try await output.loadTracks(withMediaType: .video)
    let audioTracks = try await output.loadTracks(withMediaType: .audio)
    #expect(videoTracks.count == 1)
    #expect(audioTracks.count == 1)
    try requireDecodedSample(asset: output, track: try #require(videoTracks.first),
      settings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    try requireDecodedSample(asset: output, track: try #require(audioTracks.first),
      settings: [AVFormatIDKey: kAudioFormatLinearPCM])
    let bytes = try #require(destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    #expect(bytes > 0 && bytes <= FeedbackVideoRecovery.maximumBytes)
  }

  /// Creates all test media locally: one second of blue video and a 440 Hz tone.
  /// No bundled, downloaded, microphone, or camera content enters this fixture.
  private func makeRecording(in directory: URL) async throws -> URL {
    let videoURL = directory.appendingPathComponent("video.mov")
    let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 320,
      AVVideoHeightKey: 240,
    ])
    writer.add(video)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 320,
        kCVPixelBufferHeightKey as String: 240,
      ])
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
      nil, &buffer) == kCVReturnSuccess)
    let frame = try #require(buffer)
    CVPixelBufferLockBaseAddress(frame, [])
    let address = try #require(CVPixelBufferGetBaseAddress(frame))
    let stride = CVPixelBufferGetBytesPerRow(frame)
    let pixels = address.assumingMemoryBound(to: UInt8.self)
    for row in 0..<240 {
      for column in 0..<320 {
        let offset = row * stride + column * 4
        pixels[offset] = 180; pixels[offset + 1] = 80
        pixels[offset + 2] = 20; pixels[offset + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(frame, [])
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let deadline = Date().addingTimeInterval(10)
    for index in 0..<30 {
      while !video.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(video.isReadyForMoreMediaData)
      #expect(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
    }
    writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
    video.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)

    let audioURL = directory.appendingPathComponent("tone.caf")
    try writeTone(to: audioURL)
    let videoAsset = AVURLAsset(url: videoURL)
    let audioAsset = AVURLAsset(url: audioURL)
    let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
    let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
    let composition = AVMutableComposition()
    let videoComposition = try #require(composition.addMutableTrack(withMediaType: .video,
      preferredTrackID: kCMPersistentTrackID_Invalid))
    let audioComposition = try #require(composition.addMutableTrack(withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid))
    let range = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
    try videoComposition.insertTimeRange(range, of: videoTrack, at: .zero)
    try audioComposition.insertTimeRange(range, of: audioTrack, at: .zero)
    let source = directory.appendingPathComponent("original.mov")
    let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
    export.outputURL = source
    export.outputFileType = .mov
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      export.exportAsynchronously { continuation.resume() }
    }
    #expect(export.status == .completed)
    return source
  }

  private func writeTone(to url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
    buffer.frameLength = 44_100
    let samples = try #require(buffer.floatChannelData)[0]
    for index in 0..<44_100 {
      samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.2)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }

  private func requireDecodedSample(asset: AVAsset, track: AVAssetTrack,
    settings: [String: Any]) throws {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    #expect(reader.startReading())
    let sample = try #require(output.copyNextSampleBuffer())
    #expect(CMSampleBufferGetNumSamples(sample) > 0)
    reader.cancelReading()
  }
}
