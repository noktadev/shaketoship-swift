@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import ShakeToShip

#if canImport(UIKit)
  /// Records every call so the policy is proved without a live audio route.
  private final class FakeAudioSession: FeedbackAudioSessioning {
    var category: AVAudioSession.Category = .soloAmbient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var active = false
    var calls: [String] = []
    var failCategory = false
    func setCategory(
      _ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
      options: AVAudioSession.CategoryOptions
    ) throws {
      calls.append("category \(category.rawValue) \(mode.rawValue)")
      if failCategory, category == .playback { throw CocoaError(.featureUnsupported) }
      self.category = category
      self.mode = mode
      categoryOptions = options
    }
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
      calls.append("active \(active) notify=\(options.contains(.notifyOthersOnDeactivation))")
      self.active = active
    }
  }

  @Suite struct FeedbackPreviewAudioTests {
    @Test @MainActor func playbackIgnoresSilentSwitchAndRestoresHostSession() {
      let session = FakeAudioSession()
      session.category = .playAndRecord
      session.categoryOptions = [.defaultToSpeaker]
      let audio = FeedbackPreviewAudio(session: session)
      audio.begin()
      #expect(session.category == .playback)
      #expect(session.mode == .moviePlayback)
      #expect(session.active)
      audio.begin()
      audio.end()
      #expect(!session.active)
      #expect(session.category == .playAndRecord)
      #expect(session.categoryOptions == [.defaultToSpeaker])
      #expect(
        session.calls == [
          "category \(AVAudioSession.Category.playback.rawValue) \(AVAudioSession.Mode.moviePlayback.rawValue)",
          "active true notify=false", "active false notify=true",
          "category \(AVAudioSession.Category.playAndRecord.rawValue) \(AVAudioSession.Mode.default.rawValue)",
        ])
      audio.end()
      #expect(session.calls.count == 4)
    }

    @Test @MainActor func failedCategoryLeavesTheHostSessionUntouched() {
      let session = FakeAudioSession()
      session.failCategory = true
      let audio = FeedbackPreviewAudio(session: session)
      audio.begin()
      #expect(!audio.isActive)
      #expect(session.category == .soloAmbient)
      audio.end()
      #expect(!session.calls.contains { $0.hasPrefix("active") })
    }
  }
#endif

@Suite struct FeedbackTranscriptTests {
  private let segments: [FeedbackTranscriptSegment] = [
    .init(id: 0, text: "Open practice.", start: 0.2, end: 1.4),
    .init(id: 1, text: "The button does nothing.", start: 2.0, end: 3.6),
    .init(id: 2, text: "Then it crashes.", start: 4.1, end: 5.0),
  ]

  @Test func onlyTrimmedInSpeechIsVisible() {
    let visible = FeedbackTranscript.visible(segments, in: .init(start: 1.5, end: 4.4))
    #expect(visible.map(\.id) == [1])
    #expect(FeedbackTranscript.visible(segments, in: .init(start: 0, end: 5)).count == 3)
    #expect(FeedbackTranscript.current(segments, at: 2.5)?.id == 1)
    #expect(FeedbackTranscript.current(segments, at: 1.8) == nil)
  }

  @Test func trimExcludesEveryBoundaryCrossingPhrase() {
    let phrases: [FeedbackTranscriptSegment] = [
      .init(id: 0, text: "Crosses start", start: 1, end: 3),
      .init(id: 1, text: "Inside", start: 2, end: 4),
      .init(id: 2, text: "Crosses end", start: 3, end: 5),
      .init(id: 3, text: "Contains selection", start: 0, end: 10),
      .init(id: 4, text: "Before", start: 0, end: 1),
      .init(id: 5, text: "After", start: 5, end: 6),
    ]
    let visible = FeedbackTranscript.visible(phrases, in: .init(start: 2, end: 4))
    #expect(visible.map(\.id) == [1])
    #expect(
      FeedbackTranscript.note("Note", transcript: FeedbackTranscript.text(visible))
        == "Note\n\n--- On-device transcript ---\nInside\n--- End of transcript ---")
    #expect(FeedbackTranscript.visible([phrases[3]], in: .init(start: 4, end: 6)).isEmpty)
  }

  @Test func transcriptRidesInAMarkedNoteBlock() {
    #expect(
      FeedbackTranscript.note("Tap fails", transcript: "The button does nothing.")
        == "Tap fails\n\n--- On-device transcript ---\nThe button does nothing.\n--- End of transcript ---"
    )
    #expect(
      FeedbackTranscript.note("", transcript: "Hello")
        == "--- On-device transcript ---\nHello\n--- End of transcript ---")
    #expect(FeedbackTranscript.note("Tap fails", transcript: "  ") == "Tap fails")
    #expect(FeedbackTranscript.note("Tap fails", transcript: nil) == "Tap fails")
  }

  @Test func wordsGroupIntoPhrasesAtPausesAndSentenceEnds() {
    let phrases = FeedbackTranscript.phrases([
      ("Open", 0, 0.3), ("practice.", 0.35, 0.8), ("Then", 0.9, 1.1), ("wait", 1.15, 1.4),
      ("here", 2.5, 2.8),
    ])
    #expect(phrases.map(\.text) == ["Open practice.", "Then wait", "here"])
    #expect(phrases.map(\.id) == [0, 1, 2])
    #expect(phrases[1].start == 0.9 && phrases[1].end == 1.4)
  }
}

@Suite(.serialized) struct FeedbackReviewAudioTrackTests {
  /// Joined pause/resume segments and the trimmed Send export both keep decodable audio.
  @Test func audioSurvivesSegmentJoinAndTrimExport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clip = try await FeedbackVideoCompressionIntegrationTests().makeRecording(in: directory)
    try FileManager.default.copyItem(
      at: clip, to: directory.appendingPathComponent("recording.mov"))
    try FileManager.default.copyItem(
      at: clip, to: directory.appendingPathComponent("recording-002.mov"))
    let session = FeedbackSession(
      session_id: "capture", app: "test", build: "1", started_at: "now", events: [],
      segments: [.init(file: "recording.mov"), .init(file: "recording-002.mov")])
    try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("events.json"))
    let source = try await FeedbackRecordingEdit.source(
      in: directory,
      fallback: directory.appendingPathComponent("recording.mov"))
    #expect(source.lastPathComponent == ".review-joined.mov")
    #expect(try await AVURLAsset(url: source).loadTracks(withMediaType: .audio).count == 1)
    _ = try await FeedbackRecordingEdit.prepare(
      source: source, in: directory,
      range: .init(start: 0.5, end: 1.5), context: nil, events: [])
    let exported = AVURLAsset(url: FeedbackRecordingEdit.file("recording.mov", in: directory))
    let audio = try #require(try await exported.loadTracks(withMediaType: .audio).first)
    let reader = try AVAssetReader(asset: exported)
    let output = AVAssetReaderTrackOutput(
      track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    reader.add(output)
    #expect(reader.startReading())
    let sample = try #require(output.copyNextSampleBuffer())
    #expect(CMSampleBufferGetNumSamples(sample) > 0)
    reader.cancelReading()
  }

  @Test func transcriptionAudioExtractsOnlyWhenTheFileHasSound() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clip = try await FeedbackVideoCompressionIntegrationTests().makeRecording(in: directory)
    let m4a = directory.appendingPathComponent("audio.m4a")
    #expect(try await FeedbackTranscription.extractAudio(from: clip, to: m4a))
    #expect(try await AVURLAsset(url: m4a).loadTracks(withMediaType: .audio).count == 1)
    let silent = directory.appendingPathComponent("video.mov")
    #expect(try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio).isEmpty)
    #expect(
      try await !FeedbackTranscription.extractAudio(
        from: silent, to: directory.appendingPathComponent("none.m4a")))
  }
}

#if canImport(UIKit)
  @Suite @MainActor struct FeedbackEditedTranscriptTests {
    private func editor() -> FeedbackRecordingEditor {
      let editor = FeedbackRecordingEditor()
      editor.range = .init(start: 0, end: 10)
      editor.transcript = [
        .init(id: 0, text: "Removed words", start: 0, end: 3),
        .init(id: 1, text: "Remaining words", start: 4, end: 6),
        .init(id: 2, text: "Other words", start: 8, end: 10),
      ]
      return editor
    }

    @Test func changingEitherTrimBoundaryInvalidatesManualEdits() {
      let editor = editor()
      editor.transcriptEdit = "Manually edited removed words"
      editor.range.start = 4
      #expect(editor.transcriptEdit == nil)
      #expect(editor.transcriptForSend == "Remaining words Other words")
      editor.transcriptEdit = "Another edit of removed words"
      editor.range.end = 6
      #expect(editor.transcriptEdit == nil)
      #expect(editor.transcriptForSend == "Remaining words")
    }

    @Test func wideningRangeAlsoReplacesEditedTextWithTimedSpeech() {
      let editor = editor()
      editor.range = .init(start: 4, end: 6)
      editor.transcriptEdit = "Edited selected words"
      #expect(editor.transcriptForSend == "Edited selected words")
      editor.range = .init(start: 0, end: 10)
      #expect(editor.transcriptEdit == nil)
      #expect(editor.transcriptForSend == "Removed words Remaining words Other words")
    }

    @Test func unchangedRangePreservesEditsAndRangeChangesPreserveRemoval() {
      let editor = editor()
      editor.transcriptEdit = "Approved words"
      editor.range = .init(start: 0, end: 10)
      #expect(editor.transcriptForSend == "Approved words")
      editor.transcriptRemoved = true
      editor.range.start = 4
      #expect(editor.transcriptForSend == nil)
    }
  }
#endif
