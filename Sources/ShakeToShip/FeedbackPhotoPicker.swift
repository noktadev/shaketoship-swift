#if canImport(UIKit) && canImport(PhotosUI)
import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What one picker session produced: the items that passed every bound, their
/// combined size, and the first bound that refused something.
struct FeedbackPhotoPickerOutcome: Sendable {
  let accepted: [FeedbackMediaItem]
  let acceptedBytes: Int
  let rejection: FeedbackAttachmentRejection?

  static let empty = FeedbackPhotoPickerOutcome(accepted: [], acceptedBytes: 0, rejection: nil)
}

/// `PHPickerViewController`, wrapped.
///
/// It runs OUT OF PROCESS. That is the entire reason it is used rather than a
/// hand-rolled library browser: the app never touches `PHPhotoLibrary`, so it
/// needs no photo-library authorization and ships no
/// `NSPhotoLibraryUsageDescription`. Replacing this with anything that reads
/// the library directly re-introduces a permission prompt and an App Store
/// privacy declaration for every host app that adopts the SDK.
struct FeedbackPhotoPicker: UIViewControllerRepresentable {
  /// Slots still free in the composer - never a fixed 3, or a selection could
  /// overshoot the cap and have to be trimmed after the user made it.
  let selectionLimit: Int
  /// Where accepted items are written. Inside the session dir, so Discard's
  /// single directory removal takes them too.
  let stagingDirectory: URL
  let maxAttachmentDuration: TimeInterval
  let existingCount: Int
  let existingBytes: Int
  let onFinish: (FeedbackPhotoPickerOutcome) -> Void

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration()
    configuration.selectionLimit = selectionLimit
    configuration.filter = .any(of: [.images, .videos])
    // The item itself, not a synced placeholder: `.current` avoids a download
    // the composer would have to wait on.
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: PHPickerViewController, context: Context) {
    context.coordinator.parent = self
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  @MainActor
  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    var parent: FeedbackPhotoPicker

    init(_ parent: FeedbackPhotoPicker) {
      self.parent = parent
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      guard !results.isEmpty else {
        parent.onFinish(.empty)
        return
      }
      // `sending`, because `NSItemProvider` is not Sendable and `ingest` is
      // nonisolated: handing it the array crosses an isolation boundary. The
      // array is built fresh here and read nowhere else afterwards, so the
      // transfer is genuinely exclusive and `sending` states that rather than
      // suppressing it.
      //
      // Xcode 26.3 accepts this without the annotation; the toolchain Xcode
      // Cloud tracks as "Latest Release" does not, and failed every archive
      // from 2026-08-14 with "Sending 'providers' risks causing data races" -
      // including builds whose commits changed nothing here. It is a real
      // boundary either way, so it is annotated rather than pinned around.
      let providers = results.map(\.itemProvider)
      let parent = parent
      Task { @MainActor in
        let outcome = await FeedbackAttachmentIntake.ingest(
          providers: providers,
          stagingDirectory: parent.stagingDirectory,
          maxAttachmentDuration: parent.maxAttachmentDuration,
          existingCount: parent.existingCount,
          existingBytes: parent.existingBytes)
        parent.onFinish(outcome)
      }
    }
  }
}

/// Turns picked providers into staged files that satisfy every bound.
///
/// Split out of the picker so the ordering is legible: stage the bytes, measure
/// them, THEN admit. Nothing is added to the composer that has not already
/// passed `FeedbackAttachmentBounds.admit`, and anything refused is deleted
/// rather than left in the session dir where the uploader would find it.
enum FeedbackAttachmentIntake {
  static func ingest(
    providers: sending [NSItemProvider],
    stagingDirectory: URL,
    maxAttachmentDuration: TimeInterval,
    existingCount: Int,
    existingBytes: Int
  ) async -> FeedbackPhotoPickerOutcome {
    try? FileManager.default.createDirectory(
      at: stagingDirectory, withIntermediateDirectories: true)

    var accepted: [FeedbackMediaItem] = []
    var acceptedBytes = 0
    var rejection: FeedbackAttachmentRejection?

    for provider in providers {
      let count = existingCount + accepted.count
      // Cheap check first: with no slot left there is nothing to stage, so do
      // not spend a copy or a re-encode on an item that cannot be admitted.
      if count >= FeedbackAttachmentBounds.maxItems {
        rejection = rejection ?? .tooManyItems(limit: FeedbackAttachmentBounds.maxItems)
        continue
      }
      guard let staged = await stage(provider: provider, in: stagingDirectory) else {
        rejection = rejection ?? .unreadable
        continue
      }
      let refusal = FeedbackAttachmentBounds.admit(
        staged.candidate,
        existingCount: count,
        existingBytes: existingBytes + acceptedBytes,
        maxAttachmentDuration: maxAttachmentDuration)
      if let refusal {
        // Refused items must not survive in the session dir: the uploader
        // walks that directory, and a rejected 12-minute video left behind
        // would be uploaded and metered anyway.
        try? FileManager.default.removeItem(at: staged.url)
        rejection = rejection ?? refusal
        continue
      }
      accepted.append(.picked(staged.url, staged.candidate.kind))
      acceptedBytes += staged.candidate.byteCount
    }

    return FeedbackPhotoPickerOutcome(
      accepted: accepted, acceptedBytes: acceptedBytes, rejection: rejection)
  }

  private struct Staged {
    let url: URL
    let candidate: FeedbackAttachmentCandidate
  }

  private static func stage(provider: NSItemProvider, in directory: URL) async -> Staged? {
    let name = UUID().uuidString
    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      let destination = directory.appendingPathComponent(
        "\(name).\(FeedbackMediaKind.video.fileExtension)")
      guard await copyFile(provider: provider, to: destination) else { return nil }
      let duration = await videoDuration(of: destination)
      return Staged(
        url: destination,
        candidate: FeedbackAttachmentCandidate(
          kind: .video, durationSeconds: duration, byteCount: byteCount(of: destination)))
    }
    guard let source = await loadData(provider: provider, type: UTType.image.identifier),
      let jpeg = await reencodeJPEG(source)
    else { return nil }
    let destination = directory.appendingPathComponent(
      "\(name).\(FeedbackMediaKind.image.fileExtension)")
    guard (try? jpeg.write(to: destination, options: .atomic)) != nil else { return nil }
    return Staged(
      url: destination,
      candidate: FeedbackAttachmentCandidate(
        kind: .image, durationSeconds: nil, byteCount: jpeg.count))
  }

  /// The provider's file is deleted the moment the completion handler returns,
  /// so the copy happens inside it rather than after an await.
  private static func copyFile(provider: NSItemProvider, to destination: URL) async -> Bool {
    await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
        guard let url else {
          continuation.resume(returning: false)
          return
        }
        // A fresh FileManager, not `.default`: this closure runs on whatever
        // queue the provider chose.
        let files = FileManager()
        try? files.removeItem(at: destination)
        do {
          try files.copyItem(at: url, to: destination)
          continuation.resume(returning: true)
        } catch {
          continuation.resume(returning: false)
        }
      }
    }
  }

  private static func loadData(provider: NSItemProvider, type: String) async -> Data? {
    await withCheckedContinuation { continuation in
      provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
        continuation.resume(returning: data)
      }
    }
  }

  /// Re-encodes to JPEG at a bounded maximum dimension. Off the main thread: a
  /// 48-megapixel photo decodes slowly, and the composer is on screen.
  private static func reencodeJPEG(_ data: Data) async -> Data? {
    await Task.detached(priority: .userInitiated) { () -> Data? in
      guard let image = UIImage(data: data) else { return nil }
      let limit = FeedbackAttachmentBounds.maxImageDimension
      let longest = max(image.size.width, image.size.height)
      let scale = longest > limit ? limit / longest : 1
      let target = CGSize(
        width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
      let renderer = UIGraphicsImageRenderer(size: target, format: {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // target is already in pixels.
        format.opaque = true
        return format
      }())
      let resized = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
      }
      return resized.jpegData(compressionQuality: FeedbackAttachmentBounds.jpegCompressionQuality)
    }.value
  }

  /// nil when the duration cannot be read - `FeedbackAttachmentBounds.admit`
  /// treats that as a rejection, never as a pass.
  private static func videoDuration(of url: URL) async -> TimeInterval? {
    let asset = AVURLAsset(url: url)
    guard let duration = try? await asset.load(.duration) else { return nil }
    let seconds = CMTimeGetSeconds(duration)
    return seconds.isFinite && seconds >= 0 ? seconds : nil
  }

  private static func byteCount(of url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
  }
}
#endif
