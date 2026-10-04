import AVFoundation
import Foundation

/// Only a recent amplitude survives the capture callback. No audio is retained here.
final class FeedbackMicrophoneLevel: @unchecked Sendable {
  static let shared = FeedbackMicrophoneLevel()
  private let lock = NSLock()
  private var amplitude = 0.0
  private var updated = Date.distantPast

  var current: Double {
    lock.lock()
    defer { lock.unlock() }
    return Date().timeIntervalSince(updated) < 0.4 ? amplitude : 0
  }

  func update(_ sample: CMSampleBuffer, muted: Bool) {
    var peak = 0.0
    if !muted, let format = CMSampleBufferGetFormatDescription(sample),
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
      description.mFormatID == kAudioFormatLinearPCM,
      let block = CMSampleBufferGetDataBuffer(sample) {
      let count = min(CMBlockBufferGetDataLength(block), 4096)
      var bytes = [UInt8](repeating: 0, count: count)
      let status: OSStatus = count == 0 ? -1 : bytes.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
      }
      if status == kCMBlockBufferNoErr {
        bytes.withUnsafeBytes { raw in
          if description.mBitsPerChannel == 32, description.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            for offset in stride(from: 0, to: count - count % 4, by: 4) {
              let value = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
              if value.isFinite { peak = max(peak, Double(abs(value))) }
            }
          } else if description.mBitsPerChannel == 16 {
            for offset in stride(from: 0, to: count - count % 2, by: 2) {
              peak = max(peak, abs(Double(raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768)
            }
          }
        }
      }
    }
    lock.lock()
    amplitude = min(1, max(0, peak))
    updated = Date()
    lock.unlock()
  }
}
