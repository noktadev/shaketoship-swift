import Foundation
import Testing

@testable import ShakeToShip

/// P2 recording-first submission. The entry leads with Record only where a
/// recording can start now; the recorded path sends with an optional note and
/// no title.
@Suite struct FeedbackRecordingFirstEntryTests {
  private let all: Capabilities = [.text, .screenRecording, .photoLibrary]

  @Test func aRecordingHostLeadsWithRecordThenWriteItInstead() {
    #expect(
      FeedbackComposerRules.hubEntryActions(capabilities: all, recordingAvailable: true, hub: [.ideas, .inbox])
        == [.record, .write, .suggest, .ideas, .inbox])
  }

  /// No dead Record button: an unavailable recorder keeps the existing text entry.
  @Test func anUnavailableRecorderKeepsTheReportRow() {
    #expect(
      FeedbackComposerRules.hubEntryActions(capabilities: all, recordingAvailable: false, hub: [.ideas])
        == [.report, .suggest, .ideas])
    #expect(
      FeedbackComposerRules.hubEntryActions(
        capabilities: [.text, .photoLibrary], recordingAvailable: true, hub: [.inbox])
        == [.report, .inbox])
  }

  @Test func hubOptionsOnlyAddTheirOwnRows() {
    #expect(
      FeedbackComposerRules.hubEntryActions(capabilities: all, recordingAvailable: true, hub: [])
        == [.record, .write])
  }

  /// Write it instead promises a text field. Without `.text` the form keeps its Report a bug row.
  @Test func aRecordingHostWithoutTextKeepsTheReportRowInsteadOfWrite() {
    #expect(
      FeedbackComposerRules.hubEntryActions(
        capabilities: [.screenRecording, .photoLibrary], recordingAvailable: true, hub: [.ideas])
        == [.record, .report, .suggest, .ideas])
    #expect(
      FeedbackComposerRules.hubEntryActions(capabilities: [.screenRecording], recordingAvailable: true, hub: [])
        == [.record, .report])
  }

  @Test func theConsentCardSecondaryTitleFollowsCapabilities() {
    #expect(FeedbackComposerRules.writeEntryTitle(capabilities: [.text, .screenRecording]) == "Write it instead")
    #expect(FeedbackComposerRules.writeEntryTitle(capabilities: [.text, .photoLibrary]) == "Write it instead")
    #expect(
      FeedbackComposerRules.writeEntryTitle(capabilities: [.photoLibrary, .screenRecording])
        == "Add an attachment instead")
    #expect(FeedbackComposerRules.writeEntryTitle(capabilities: [.screenRecording]) == nil)
  }

  @Test func theSecondaryActionSaysWriteItInstead() {
    #expect(FeedbackHubEntryAction.write.title == "Write it instead")
    #expect(FeedbackHubEntryAction.report.title == "Report a bug")
  }
}

@Suite struct FeedbackRecordedResultTests {
  private func session() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("recording-first-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func names(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
  }

  /// The model writes the title. A recording with no words is a complete report.
  @Test func aRecordingWithoutANoteIsSendableAndWritesOnlyTheRecording() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clip = dir.appendingPathComponent("recording.mov")
    try Data("capture".utf8).write(to: clip)

    let result = FeedbackComposerResult.recorded(clip, note: "")

    #expect(FeedbackComposerRules.sendEnabled(media: result.media, note: result.note))
    #expect(persistComposedReport(result, in: dir))
    #expect(names(in: dir) == ["recording.mov"])
  }

  @Test func theOptionalNoteLandsBesideTheUntouchedRecording() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }
    let clip = dir.appendingPathComponent("recording.mov")
    try Data("capture".utf8).write(to: clip)

    let result = FeedbackComposerResult.recorded(clip, note: "  Save stops responding.\n")

    #expect(result.media == [.recorded(clip)])
    #expect(persistComposedReport(result, in: dir))
    #expect(names(in: dir) == ["note.txt", "recording.mov"])
    #expect(try String(contentsOf: dir.appendingPathComponent("note.txt"), encoding: .utf8) == "Save stops responding.")
    #expect(try String(contentsOf: clip, encoding: .utf8) == "capture")
  }
}

/// The review card's note lives in the unconfirmed capture directory, so a
/// dismissal or background interruption keeps it for the recovery offer.
@Suite struct FeedbackRecordedNoteDraftTests {
  private func session() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("recorded-note-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("capture".utf8).write(to: dir.appendingPathComponent("recording.mov"))
    return dir
  }

  @Test func aTypedNoteSurvivesUntilTheRecoveryOfferReadsIt() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(FeedbackRecordedNoteDraft.save("Checkout spins forever.", in: dir))

    #expect(FeedbackRecordedNoteDraft.load(in: dir) == "Checkout spins forever.")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".confirmed").path))
  }

  @Test func clearingTheNoteRemovesTheDraft() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(FeedbackRecordedNoteDraft.save("first", in: dir))

    #expect(FeedbackRecordedNoteDraft.save("  ", in: dir))

    #expect(FeedbackRecordedNoteDraft.load(in: dir) == "")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("note.txt").path))
  }

  /// Send writes the final note over the draft; the recording stays untouched.
  @Test func sendReplacesTheDraftWithTheSentNote() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(FeedbackRecordedNoteDraft.save("draft", in: dir))

    #expect(persistComposedReport(.recorded(dir.appendingPathComponent("recording.mov"), note: "final"), in: dir))

    #expect(FeedbackRecordedNoteDraft.load(in: dir) == "final")
    #expect(try String(contentsOf: dir.appendingPathComponent("recording.mov"), encoding: .utf8) == "capture")
  }
}

/// Dismissal at the recovery seam: the capture and its note stay for the offer.
/// Production Discard deletion is a device check; see the Harness README.
@Suite struct FeedbackRecordedReviewExitTests {
  private func retainedCapture(in root: URL) throws -> URL {
    let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("capture".utf8).write(to: dir.appendingPathComponent("recording.mov"))
    #expect(writeFeedbackInterruptedMarker(in: dir))
    return dir
  }

  @Test func dismissalKeepsTheCaptureAndNoteForTheRecoveryOffer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("exit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try retainedCapture(in: root)
    #expect(FeedbackRecordedNoteDraft.save("Keep this note", in: dir))

    let pending = pendingInterruptedSessions(root: root)

    #expect(pending.map(\.dir.lastPathComponent) == [dir.lastPathComponent])
    #expect(FeedbackRecordedNoteDraft.load(in: pending[0].dir) == "Keep this note")
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".confirmed").path))
  }
}
