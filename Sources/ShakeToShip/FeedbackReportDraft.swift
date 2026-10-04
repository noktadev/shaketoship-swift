import Foundation
@preconcurrency import AVFoundation

struct FeedbackComposerDraftValue: Equatable, Sendable {
  var title: String
  var note: String
  var media: [FeedbackMediaItem]
}

/// A single unsent report, scoped to the current reporter identity.
struct FeedbackReportDraft: Codable, Equatable, Sendable {
  let id: String
  let directory: URL
  let generation: UUID
  var title = ""
  var note = ""
  var media: [FeedbackMediaItem] = []
  var events: [FeedbackEvent] = []
  var captureID: String?

  mutating func update(_ value: FeedbackComposerDraftValue) {
    title = value.title
    note = value.note
    media = value.media
    if !media.contains(where: \.isRecorded) { events = [] }
  }
}

struct FeedbackReportDraftStore: Sendable {
  static let marker = ".hub-report-draft"
  private static let file = "report-draft.json"
  let storage: FeedbackHubStorage
  let generation: UUID
  let outboxRoot: URL
  static var defaultOutboxRoot: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("feedback-outbox", isDirectory: true)
  }
  init(storage: FeedbackHubStorage, generation: UUID, outboxRoot: URL = Self.defaultOutboxRoot) {
    self.storage = storage
    self.generation = generation
    self.outboxRoot = outboxRoot
  }
  func ownsDirectory(_ directory: URL) -> Bool {
    directory.isFileURL && UUID(uuidString: directory.lastPathComponent) != nil &&
      directory.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL ==
        outboxRoot.resolvingSymlinksInPath().standardizedFileURL
  }

  func load() throws -> FeedbackReportDraft? {
    guard let draft = try storage.read(FeedbackReportDraft.self, file: Self.file) else { return nil }
    try validate(draft)
    return draft
  }
  func save(_ draft: FeedbackReportDraft) throws {
    try validate(draft)
    try Data().write(to: draft.directory.appendingPathComponent(Self.marker), options: .atomic)
    try storage.write(draft, file: Self.file)
  }
  func clear(id: String) throws {
    guard let draft = try storage.read(FeedbackReportDraft.self, file: Self.file), draft.id == id else { return }
    try validate(draft)
    let marker = draft.directory.appendingPathComponent(Self.marker)
    if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    do { try FileManager.default.removeItem(at: storage.root.appendingPathComponent(Self.file)) }
    catch { try? Data().write(to: marker, options: .atomic); throw error }
  }
  private func validate(_ draft: FeedbackReportDraft) throws {
    guard draft.generation == generation, UUID(uuidString: draft.id) != nil,
      draft.directory.lastPathComponent == draft.id, ownsDirectory(draft.directory),
      let binding = try FeedbackCaptureBinding.read(in: draft.directory),
      binding.scope == storage.scope, binding.generation == generation, binding.purpose == .report,
      draft.captureID.map({ UUID(uuidString: $0) != nil }) ?? true else {
      throw FeedbackHubError.identityChanged
    }
    let root = draft.directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    guard draft.media.allSatisfy({ $0.url.isFileURL && $0.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) }) else {
      throw FeedbackHubError.storage
    }
  }
}

protocol FeedbackVideoJoining: Sendable {
  func join(_ sources: [URL], to destination: URL) async throws
}

/// Pause/resume segments become one attachment, with their original audio and video.
struct AVFeedbackVideoJoiner: FeedbackVideoJoining {
  func join(_ sources: [URL], to destination: URL) async throws {
    guard !sources.isEmpty else { throw FeedbackRecorderError.emptyRecording }
    if sources.count == 1 {
      let asset = AVURLAsset(url: sources[0])
      let duration = try await asset.load(.duration)
      guard duration.isValid, duration.seconds > 0,
        !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
        throw FeedbackVideoRecoveryError.invalidMedia
      }
      try FileManager.default.copyItem(at: sources[0], to: destination)
      return
    }
    let composition = AVMutableComposition()
    guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw FeedbackVideoRecoveryError.invalidMedia
    }
    var offset = CMTime.zero
    for source in sources {
      let asset = AVURLAsset(url: source)
      let duration = try await asset.load(.duration)
      guard duration.isValid, duration.seconds > 0,
        let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
        throw FeedbackVideoRecoveryError.invalidMedia
      }
      let range = CMTimeRange(start: .zero, duration: duration)
      try video.insertTimeRange(range, of: sourceVideo, at: offset)
      if offset == .zero { video.preferredTransform = try await sourceVideo.load(.preferredTransform) }
      if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
        try audio.insertTimeRange(range, of: sourceAudio, at: offset)
      }
      offset = CMTimeAdd(offset, duration)
    }
    guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
      throw FeedbackVideoRecoveryError.unsupported
    }
    exporter.outputURL = destination
    exporter.outputFileType = .mov
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      exporter.exportAsynchronously { continuation.resume() }
    }
    guard exporter.status == .completed else { throw exporter.error ?? FeedbackVideoRecoveryError.invalidMedia }
  }
}

/// Uses the normal recorder as a capture source; only the original draft is sent.
@MainActor
final class FeedbackReportRecording {
  let store: FeedbackReportDraftStore
  let draftID: String
  init(store: FeedbackReportDraftStore, draftID: String) {
    self.store = store
    self.draftID = draftID
  }
  func beginCapture(in directory: URL) throws {
    guard store.ownsDirectory(directory), var draft = try store.load(), draft.id == draftID,
      draft.media.count < FeedbackAttachmentBounds.maxItems,
      let binding = try FeedbackCaptureBinding.read(in: directory),
      binding.scope == store.storage.scope, binding.generation == store.generation, binding.purpose == .report else {
      throw FeedbackHubError.storage
    }
    guard draft.captureID == nil else { throw FeedbackHubError.storage }
    draft.captureID = directory.lastPathComponent
    try store.save(draft)
    try Data().write(to: directory.appendingPathComponent(FeedbackReportDraftStore.marker), options: .atomic)
  }
  @discardableResult
  func completeCapture(in directory: URL, session: FeedbackSession,
    joiner: any FeedbackVideoJoining = AVFeedbackVideoJoiner()) async throws -> FeedbackReportDraft {
    guard store.ownsDirectory(directory), var draft = try store.load(), draft.id == draftID,
      draft.captureID == directory.lastPathComponent,
      let binding = try FeedbackCaptureBinding.read(in: directory),
      binding.scope == store.storage.scope, binding.generation == store.generation, binding.purpose == .report else {
      throw FeedbackHubError.identityChanged
    }
    let names = session.segments?.map(\.file) ?? ["recording.mov"]
    guard !names.isEmpty, names.allSatisfy(Self.isRecordingFile) else { throw FeedbackHubError.invalidResponse }
    let staging = draft.directory.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let joined = staging.appendingPathComponent(UUID().uuidString + ".mov")
    do {
      try await joiner.join(names.map { directory.appendingPathComponent($0) }, to: joined)
      // A reset/discard while export suspends must not restore the old draft.
      guard let current = try store.load(), current.id == draftID, current.captureID == draft.captureID else {
        throw FeedbackHubError.identityChanged
      }
      draft = current
      guard draft.media.count < FeedbackAttachmentBounds.maxItems else { throw FeedbackHubError.storage }
      if draft.media.contains(where: \.isRecorded) {
        let bytes = try joined.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let existingBytes = draft.media.filter { !$0.isRecorded }.reduce(0) {
          $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard bytes > 0, bytes + existingBytes <= FeedbackAttachmentBounds.maxTotalBytes else {
          throw FeedbackVideoRecoveryError.tooLarge
        }
        draft.media.append(.picked(joined, .video))
      } else {
        let recording = draft.directory.appendingPathComponent("recording.mov")
        if FileManager.default.fileExists(atPath: recording.path) { try FileManager.default.removeItem(at: recording) }
        try FileManager.default.copyItem(at: joined, to: recording)
        draft.media.append(.recorded(recording))
        draft.events = session.events
      }
      draft.captureID = nil
      try store.save(draft)
      if draft.media.contains(where: { $0.url == joined }) == false { try? FileManager.default.removeItem(at: joined) }
      try? FileManager.default.removeItem(at: directory)
      return draft
    } catch {
      try? FileManager.default.removeItem(at: joined)
      throw error
    }
  }
  private static func isRecordingFile(_ name: String) -> Bool {
    if name == "recording.mov" { return true }
    guard name.hasPrefix("recording-"), name.hasSuffix(".mov") else { return false }
    let digits = name.dropFirst(10).dropLast(4)
    return digits.count == 3 && digits.allSatisfy(\.isNumber) && Int(digits).map { $0 >= 2 && $0 <= 999 } == true
  }
}
