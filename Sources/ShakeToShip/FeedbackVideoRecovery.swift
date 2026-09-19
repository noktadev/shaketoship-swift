@preconcurrency import AVFoundation
import Foundation

/// Smaller upload copies never replace the original evidence. A process that
/// stops during export leaves its attempt marker and originals available to share.
protocol FeedbackVideoCompressing: Sendable {
  func compress(source: URL, destination: URL, maximumBytes: Int) async throws
}

enum FeedbackVideoRecoveryError: Error {
  case unsupported, invalidMedia, tooLarge
}

struct FeedbackVideoMeasurements: Sendable {
  let duration: Double
  let videoTracks: Int
  let audioTracks: Int

  func preserves(_ source: Self) -> Bool {
    duration.isFinite && source.duration.isFinite && source.duration > 0
      && abs(duration - source.duration) <= 0.25
      && videoTracks == source.videoTracks && videoTracks > 0
      && audioTracks == source.audioTracks
  }
}

struct AVFeedbackVideoCompressor: FeedbackVideoCompressing {
  func compress(source: URL, destination: URL, maximumBytes: Int) async throws {
    let asset = AVURLAsset(url: source)
    let before = try await measurements(asset)
    guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality),
      exporter.supportedFileTypes.contains(.mov) else {
      throw FeedbackVideoRecoveryError.unsupported
    }
    exporter.outputURL = destination
    exporter.outputFileType = .mov
    exporter.shouldOptimizeForNetworkUse = true
    // Do not set timeRange or fileLengthLimit: either could silently lose the end.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      exporter.exportAsynchronously { continuation.resume() }
    }
    try Task.checkCancellation()
    guard exporter.status == .completed else {
      throw exporter.error ?? FeedbackVideoRecoveryError.invalidMedia
    }
    let after = try await measurements(AVURLAsset(url: destination))
    guard after.preserves(before) else { throw FeedbackVideoRecoveryError.invalidMedia }
    let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard bytes > 0, bytes <= maximumBytes else { throw FeedbackVideoRecoveryError.tooLarge }
  }

  private func measurements(_ asset: AVURLAsset) async throws -> FeedbackVideoMeasurements {
    let duration = try await asset.load(.duration)
    let video = try await asset.loadTracks(withMediaType: .video)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    return FeedbackVideoMeasurements(duration: duration.seconds, videoTracks: video.count,
      audioTracks: audio.count)
  }
}

struct FeedbackRetainedRecording: Identifiable, Sendable {
  let sessionId: String
  let originalFiles: [URL]
  let createdAt: Date
  var id: String { sessionId }
}

/// An atomic marker bounds compression to one attempt, including after a crash.
/// A ready marker is written only after every output passes validation.
struct FeedbackVideoRecovery {
  static let maximumBytes = 80 * 1024 * 1024
  private static let markerName = ".video-recovery.json"
  private static let directoryName = ".upload-recovery"
  private struct State: Codable {
    let ready: Bool
    let files: [String: Int]
  }
  let compressor: any FeedbackVideoCompressing
  let fileManager: FileManager

  func hasAttempt(in dir: URL) -> Bool {
    fileManager.fileExists(atPath: dir.appendingPathComponent(Self.markerName).path)
  }

  func isReady(in dir: URL) -> Bool { state(in: dir)?.ready == true }

  func prepare(in dir: URL, names: [String]) async -> Bool {
    let marker = dir.appendingPathComponent(Self.markerName)
    if fileManager.fileExists(atPath: marker.path) {
      guard let state = state(in: dir), state.ready else { return false }
      return names.allSatisfy { copy(for: $0, in: dir) != nil }
    }
    guard !names.isEmpty else { return false }
    let copies = dir.appendingPathComponent(Self.directoryName, isDirectory: true)
    do {
      // Persist before starting the first export. A failed write prevents work.
      try JSONEncoder().encode(State(ready: false, files: [:])).write(to: marker, options: .atomic)
      try fileManager.createDirectory(at: copies, withIntermediateDirectories: true)
      var sizes: [String: Int] = [:]
      for name in names {
        try Task.checkCancellation()
        let temporary = copies.appendingPathComponent("partial-\(UUID().uuidString).mov")
        try await compressor.compress(source: dir.appendingPathComponent(name), destination: temporary,
          maximumBytes: Self.maximumBytes)
        let bytes = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= Self.maximumBytes else { throw FeedbackVideoRecoveryError.tooLarge }
        try fileManager.moveItem(at: temporary, to: copies.appendingPathComponent(name))
        sizes[name] = bytes
      }
      try JSONEncoder().encode(State(ready: true, files: sizes)).write(to: marker, options: .atomic)
      return true
    } catch {
      try? fileManager.removeItem(at: copies)
      return false
    }
  }

  func copy(for name: String, in dir: URL) -> URL? {
    guard let state = state(in: dir), state.ready, let bytes = state.files[name] else { return nil }
    let file = dir.appendingPathComponent(Self.directoryName).appendingPathComponent(name)
    guard let actual = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      actual.isRegularFile == true, actual.fileSize == bytes, bytes > 0,
      bytes <= Self.maximumBytes else { return nil }
    return file
  }

  private func state(in dir: URL) -> State? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.markerName)) else { return nil }
    return try? JSONDecoder().decode(State.self, from: data)
  }
}

/// Separate uploader values and launch/review tasks must not export or delete
/// the same session concurrently. The lease contains paths, never credentials.
actor FeedbackUploadLeases {
  static let shared = FeedbackUploadLeases()
  private var active: Set<String> = []
  func acquire(_ path: String) -> Bool { active.insert(path).inserted }
  func release(_ path: String) { active.remove(path) }
}
