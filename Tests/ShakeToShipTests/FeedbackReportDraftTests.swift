import Foundation
import Testing

@testable import ShakeToShip

private struct ByteJoining: FeedbackVideoJoining {
  func join(_ sources: [URL], to destination: URL) async throws {
    #expect(!sources.isEmpty)
    try Data("joined video".utf8).write(to: destination)
  }
}

private actor PausedJoining: FeedbackVideoJoining {
  private var started = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var resumeWaiter: CheckedContinuation<Void, Never>?

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func resume() {
    resumeWaiter?.resume()
    resumeWaiter = nil
  }

  func join(_ sources: [URL], to destination: URL) async throws {
    started = true
    startWaiter?.resume()
    startWaiter = nil
    await withCheckedContinuation { resumeWaiter = $0 }
    try Data("joined video".utf8).write(to: destination)
  }
}

@MainActor
@Suite(.serialized) struct FeedbackReportDraftTests {
  private struct Fixture {
    let root: URL
    let storage: FeedbackHubStorage
    let store: FeedbackReportDraftStore
    let draft: FeedbackReportDraft

    func capture(purpose: FeedbackCapturePurpose = .report, scope: String = "draft-test") throws -> URL {
      let directory = store.outboxRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let binding = FeedbackCaptureBinding(scope: scope, generation: store.generation, purpose: purpose)
      try JSONEncoder().encode(binding).write(to: directory.appendingPathComponent(FeedbackCaptureBinding.filename))
      try Data("source".utf8).write(to: directory.appendingPathComponent("recording.mov"))
      return directory
    }

    func session() -> FeedbackSession {
      FeedbackSession(session_id: UUID().uuidString, app: "test", build: "1", started_at: "2026-09-24T00:00:00Z", events: [])
    }
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    let storageRoot = root.appendingPathComponent("hub", isDirectory: true)
    let draftID = UUID().uuidString
    let draftDirectory = outbox.appendingPathComponent(draftID, isDirectory: true)
    try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
    let generation = UUID()
    let binding = FeedbackCaptureBinding(scope: "draft-test", generation: generation, purpose: .report)
    try JSONEncoder().encode(binding).write(to: draftDirectory.appendingPathComponent(FeedbackCaptureBinding.filename))
    let storage = FeedbackHubStorage(scope: "draft-test", root: storageRoot,
      readIdentity: { nil }, writeIdentity: { _ in })
    let store = FeedbackReportDraftStore(storage: storage, generation: generation, outboxRoot: outbox)
    return Fixture(root: root, storage: storage, store: store,
      draft: FeedbackReportDraft(id: draftID, directory: draftDirectory, generation: generation))
  }

  @Test func titleNoteAndMediaRestoreFromDisk() throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let image = f.draft.directory.appendingPathComponent("staging/picked.jpg")
    try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("image".utf8).write(to: image)
    var draft = f.draft
    draft.update(FeedbackComposerDraftValue(title: "Broken button", note: "Tap twice", media: [.picked(image, .image)]))
    try f.store.save(draft)

    let restored = try #require(try FeedbackReportDraftStore(
      storage: f.storage, generation: f.store.generation, outboxRoot: f.store.outboxRoot).load())
    #expect(restored.id == draft.id)
    #expect(restored.title == "Broken button")
    #expect(restored.note == "Tap twice")
    #expect(restored.media == [.picked(image, .image)])
  }

  @Test func draftSurvivesContainerRelocation() throws {
    let f = try fixture()
    let moved = f.root.appendingPathExtension("moved")
    defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: moved) }
    var draft = f.draft
    draft.note = "Keep my feedback"
    let image = draft.directory.appendingPathComponent("picked.jpg")
    try Data("image".utf8).write(to: image)
    draft.media = [.picked(image, .image)]
    try f.store.save(draft)
    try FileManager.default.moveItem(at: f.root, to: moved)
    let storage = FeedbackHubStorage(scope: f.storage.scope, root: moved.appendingPathComponent("hub"),
      readIdentity: { nil }, writeIdentity: { _ in })
    let store = FeedbackReportDraftStore(storage: storage, generation: f.store.generation,
      outboxRoot: moved.appendingPathComponent("outbox"))
    // The conversation uses this exact sequence before showing its input.
    try store.clearMissingDirectoryRecord()
    let restored = try #require(try store.load())
    #expect(restored.note == "Keep my feedback")
    #expect(restored.directory == store.outboxRoot.appendingPathComponent(draft.id, isDirectory: true))
    #expect(try Data(contentsOf: restored.media[0].url) == Data("image".utf8))
    try store.save(restored)
    try store.clear(id: restored.id)
    #expect(try store.load() == nil)
  }

  @Test(arguments: ["scope", "generation", "missing-binding", "outside-media", "symlink"])
  func relocationRejectsUnownedDataWithoutChangingTheDraft(failure: String) throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let oldDirectory = URL(fileURLWithPath: "/old-container/outbox/" + f.draft.id, isDirectory: true)
    var draft = FeedbackReportDraft(id: f.draft.id, directory: oldDirectory, generation: f.store.generation)
    draft.note = "Do not discard this message"
    if failure == "outside-media" { draft.media = [.picked(URL(fileURLWithPath: "/private/other.jpg"), .image)] }
    if failure == "symlink" {
      let outside = f.root.appendingPathComponent("outside.jpg")
      try Data("private".utf8).write(to: outside)
      try FileManager.default.createSymbolicLink(at: f.draft.directory.appendingPathComponent("link.jpg"), withDestinationURL: outside)
      draft.media = [.picked(oldDirectory.appendingPathComponent("link.jpg"), .image)]
    }
    let bindingFile = f.draft.directory.appendingPathComponent(FeedbackCaptureBinding.filename)
    if failure == "missing-binding" { try FileManager.default.removeItem(at: bindingFile) }
    if failure == "scope" || failure == "generation" {
      let binding = FeedbackCaptureBinding(scope: failure == "scope" ? "other" : f.storage.scope,
        generation: failure == "generation" ? UUID() : f.store.generation, purpose: .feedback)
      try JSONEncoder().encode(binding).write(to: bindingFile)
    }
    try f.storage.write(draft, file: "report-draft.json")
    #expect(throws: FeedbackHubError.self) { try f.store.clearMissingDirectoryRecord() }
    #expect(try f.storage.read(FeedbackReportDraft.self, file: "report-draft.json") == draft)
    #expect(FileManager.default.fileExists(atPath: f.draft.directory.path))
  }

  @Test func firstAndSecondRecordingKeepOneDraftAndCleanCaptureDirectories() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var draft = f.draft
    draft.title = "Saved title"
    draft.note = "Saved note"
    try f.store.save(draft)
    let recording = FeedbackReportRecording(store: f.store, draftID: draft.id)

    let firstCapture = try f.capture()
    try recording.beginCapture(in: firstCapture)
    let first = try await recording.completeCapture(in: firstCapture, session: f.session(), joiner: ByteJoining())
    #expect(first.id == draft.id)
    #expect(first.title == "Saved title" && first.note == "Saved note")
    #expect(first.captureID == nil)
    #expect(first.media == [.recorded(draft.directory.appendingPathComponent("recording.mov"))])
    #expect(!FileManager.default.fileExists(atPath: firstCapture.path))
    #expect(try Data(contentsOf: first.media[0].url) == Data("joined video".utf8))

    let secondCapture = try f.capture()
    try recording.beginCapture(in: secondCapture)
    let second = try await recording.completeCapture(in: secondCapture, session: f.session(), joiner: ByteJoining())
    #expect(second.id == draft.id)
    #expect(second.captureID == nil)
    #expect(second.media.count == 2)
    #expect(second.media[0].isRecorded)
    #expect(!second.media[1].isRecorded && second.media[1].kind == .video)
    #expect(second.media[1].url.path.contains("/staging/"))
    #expect(!FileManager.default.fileExists(atPath: secondCapture.path))
    #expect(try f.store.load()?.media == second.media)
  }

  @Test(arguments: [false, true]) func removedOrResetDraftDoesNotReturnAfterSuspendedJoin(reset: Bool) async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try f.store.save(f.draft)
    let recording = FeedbackReportRecording(store: f.store, draftID: f.draft.id)
    let directory = try f.capture()
    try recording.beginCapture(in: directory)
    let joining = PausedJoining()
    let task = Task { try await recording.completeCapture(in: directory, session: f.session(), joiner: joining) }
    await joining.waitUntilStarted()
    if reset { try f.storage.clearPrivateData() } else { try f.store.clear(id: f.draft.id) }
    await joining.resume()
    await #expect(throws: FeedbackHubError.self) { try await task.value }
    #expect(try f.store.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: f.draft.directory.appendingPathComponent("recording.mov").path))
  }

  @Test func mismatchedBindingCannotBeginOrCompleteRecording() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try f.store.save(f.draft)
    let recording = FeedbackReportRecording(store: f.store, draftID: f.draft.id)
    let wrong = try f.capture(scope: "another-project")
    #expect(throws: FeedbackHubError.self) { try recording.beginCapture(in: wrong) }
    #expect(try f.store.load()?.captureID == nil)
    let idea = try f.capture(purpose: .idea("private"))
    #expect(throws: FeedbackHubError.self) { try recording.beginCapture(in: idea) }
    #expect(try f.store.load()?.captureID == nil)

    let valid = try f.capture()
    try recording.beginCapture(in: valid)
    let wrongBinding = FeedbackCaptureBinding(scope: "another-project", generation: f.store.generation, purpose: .report)
    try JSONEncoder().encode(wrongBinding).write(to: valid.appendingPathComponent(FeedbackCaptureBinding.filename))
    await #expect(throws: FeedbackHubError.self) {
      try await recording.completeCapture(in: valid, session: f.session(), joiner: ByteJoining())
    }
    #expect(try f.store.load()?.captureID == valid.lastPathComponent)
  }
}
