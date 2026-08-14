import AVFoundation
import Foundation
import Testing

@testable import ShakeToShip

@Suite struct DegradationMicrophonePermissionTests {
  @Test func deniedMicrophonePermissionKeepsVideoCaptureSilent() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("sts-microphone-denied-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let inputs = try FeedbackCaptureInputs.attach(
      plan: FeedbackCapturePlan(startsScreenCapture: true, capturesMicrophone: true),
      to: writer, width: 640, height: 480)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: inputs.video,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 640,
        kCVPixelBufferHeightKey as String: 480,
      ])
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)

    #expect(status == kCVReturnSuccess)
    let frame = try #require(pixelBuffer)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    #expect(adaptor.append(frame, withPresentationTime: .zero))
    inputs.video.markAsFinished()
    inputs.audio?.markAsFinished()
    await writer.finishWriting()

    #expect(writer.status == .completed)
    let tracks = try await AVURLAsset(url: url).load(.tracks)
    #expect(tracks.filter { $0.mediaType == .video }.count == 1)
    #expect(tracks.filter { $0.mediaType == .audio }.isEmpty)
  }
}
