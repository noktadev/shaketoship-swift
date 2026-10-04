@preconcurrency import AVFoundation
@preconcurrency import CoreImage
import Foundation

struct FeedbackTrimRange: Codable, Equatable, Sendable {
  var start: Double
  var end: Double
  var duration: Double { end - start }
  func isValid(for duration: Double) -> Bool {
    start.isFinite && end.isFinite && duration.isFinite && start >= 0 && end <= duration + 0.01 && end > start
  }
  func events(_ events: [FeedbackEvent]) -> [FeedbackEvent] {
    events.filter { $0.t >= start && $0.t <= end }.map {
      switch $0 {
      case let .screen(t, name): .screen(t: t - start, name: name)
      case let .tap(t, tap): .tap(t: t - start, tap: tap)
      }
    }
  }
}

/// An atomic pointer selects complete edited evidence. Originals never enter an edited upload.
struct FeedbackRecordingEdit: Codable, Sendable {
  static let marker = ".recording-edit.json"
  let directory: String
  let duration: Double
  let range: FeedbackTrimRange

  static func read(in dir: URL) throws -> Self? {
    let marker = dir.appendingPathComponent(marker)
    guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
    let edit = try JSONDecoder().decode(Self.self, from: Data(contentsOf: marker))
    guard UUID(uuidString: edit.directory) != nil, edit.duration.isFinite, edit.duration > 0 else {
      throw FeedbackVideoRecoveryError.invalidMedia
    }
    return edit
  }

  static func file(_ name: String, in dir: URL) -> URL {
    // Callers validate the marker before any transfer. A malformed marker must never fall back to originals.
    if let edit = try? read(in: dir), name == "recording.mov" || name == "events.json" {
      return dir.appendingPathComponent(".review-edits/" + edit.directory).appendingPathComponent(name)
    }
    return dir.appendingPathComponent(name)
  }

  static func source(in dir: URL, fallback: URL) async throws -> URL {
    if try read(in: dir) != nil { return file("recording.mov", in: dir) }
    let sidecar = dir.appendingPathComponent("events.json")
    guard let data = try? Data(contentsOf: sidecar),
      let session = try? JSONDecoder().decode(FeedbackSession.self, from: data),
      let segments = session.segments, segments.count > 1 else { return fallback }
    guard segments.allSatisfy({ $0.file == "recording.mov" ||
      $0.file.range(of: #"^recording-[0-9]{3}\.mov$"#, options: .regularExpression) != nil }) else {
      throw FeedbackVideoRecoveryError.invalidMedia
    }
    let joined = dir.appendingPathComponent(".review-joined.mov")
    if FileManager.default.fileExists(atPath: joined.path) { return joined }
    let temporary = dir.appendingPathComponent(".review-joined-" + UUID().uuidString + ".mov")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try await AVFeedbackVideoJoiner().join(segments.map { dir.appendingPathComponent($0.file) }, to: temporary)
    try FileManager.default.moveItem(at: temporary, to: joined)
    return joined
  }

  static func prepare(source: URL, in dir: URL, range: FeedbackTrimRange,
    context: FeedbackDevContext?, events: [FeedbackEvent],
    annotation: CGImage? = nil) async throws -> Self {
    let path = dir.standardizedFileURL.path
    guard await FeedbackUploadLeases.shared.acquire(path) else { throw FeedbackVideoRecoveryError.invalidMedia }
    do {
      let edit = try await prepareExclusively(source: source, in: dir, range: range,
        context: context, events: events, annotation: annotation)
      await FeedbackUploadLeases.shared.release(path)
      return edit
    } catch {
      await FeedbackUploadLeases.shared.release(path)
      throw error
    }
  }

  private static func prepareExclusively(source: URL, in dir: URL, range: FeedbackTrimRange,
    context: FeedbackDevContext?, events: [FeedbackEvent], annotation: CGImage?) async throws -> Self {
    guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".confirmed").path),
      !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".upload-manifest.json").path) else {
      throw FeedbackVideoRecoveryError.invalidMedia
    }
    let asset = AVURLAsset(url: source)
    let duration = try await asset.load(.duration).seconds
    guard range.isValid(for: duration) else { throw FeedbackVideoRecoveryError.invalidMedia }
    let identifier = UUID().uuidString
    let destination = dir.appendingPathComponent(".review-edits/" + identifier, isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    do {
      let output = destination.appendingPathComponent("recording.mov")
      guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
        throw FeedbackVideoRecoveryError.unsupported
      }
      exporter.timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
        end: CMTime(seconds: range.end, preferredTimescale: 600))
      if let annotation {
        exporter.videoComposition = try await annotatedComposition(asset: asset, image: annotation)
      }
      exporter.outputURL = output
      exporter.outputFileType = .mov
      try await FeedbackMediaExport.run(exporter)
      guard exporter.status == .completed else { throw exporter.error ?? FeedbackVideoRecoveryError.invalidMedia }
      let actual = try await AVURLAsset(url: output).load(.duration).seconds
      guard actual.isFinite, actual > 0, abs(actual - range.duration) < 0.25 else {
        throw FeedbackVideoRecoveryError.invalidMedia
      }
      let originalData = try? Data(contentsOf: file("events.json", in: dir))
      let original = originalData.flatMap { try? JSONDecoder().decode(FeedbackSession.self, from: $0) }
      let sidecar = FeedbackSession(session_id: original?.session_id ?? dir.lastPathComponent,
        app: original?.app ?? Bundle.main.bundleIdentifier ?? "", build: original?.build ?? "",
        started_at: original?.started_at ?? ISO8601DateFormatter().string(from: Date()),
        user_ref: original?.user_ref, events: range.events(events),
        segments: [.init(file: "recording.mov")], dev_context: context, duration_seconds: actual)
      try JSONEncoder().encode(sidecar).write(to: destination.appendingPathComponent("events.json"), options: .atomic)
      try Task.checkCancellation()
      guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".confirmed").path),
        !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".upload-manifest.json").path) else {
        throw FeedbackVideoRecoveryError.invalidMedia
      }
      let edit = Self(directory: identifier, duration: actual, range: range)
      try JSONEncoder().encode(edit).write(to: dir.appendingPathComponent(marker), options: .atomic)
      return edit
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
  }

  private static func annotatedComposition(asset: AVAsset, image: CGImage) async throws -> AVVideoComposition {
    let overlay = CIImage(cgImage: image)
    // AVFoundation supplies upright frames. Composite immutable ink into each frame
    // without a Core Animation render server or an offscreen layer hierarchy.
    return AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
      let extent = request.sourceImage.extent
      let ink = overlay.transformed(by: CGAffineTransform(
        scaleX: extent.width / overlay.extent.width,
        y: extent.height / overlay.extent.height))
        .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
      request.finish(with: ink.composited(over: request.sourceImage).cropped(to: extent), context: nil)
    })
  }
}
