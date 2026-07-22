import Foundation
import Testing

@testable import AppFeedback

/// #669 MUST-FIX 1: backgrounding must persist the paused session durably
/// (events.json + `.interrupted` marker) so an iOS kill during the pause
/// window still lets the launch sweep discover + offer the partial, exactly
/// like a hard `stopRecording(.interruption)`. A resume must clear the marker
/// so the still-open session is not offered while it is live in-process.
///
/// These exercise the real seam `ShakeRecorderModifier.pauseRecording` /
/// `resumeRecording` call directly (`writeFeedbackPauseDurability` /
/// `clearFeedbackPauseDurability`), plus `pendingInterruptedSessions` - the
/// same scan the foreground offer and the modifier itself use. The modifier
/// is UIKit-gated and not unit tested; this is the closest testable seam to
/// the real observable effect.
@Suite struct FeedbackPauseDurabilityTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-pause-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeSessionDir(_ root: URL, _ id: String) throws -> URL {
    let dir = root.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: dir.appendingPathComponent("recording.mov"))
    return dir
  }

  @Test func pauseWithoutResumeLeavesSessionOfferable() throws {
    let root = try makeRoot()
    let dir = try makeSessionDir(root, "s1")
    let session = FeedbackSession(
      session_id: "s1", app: "dotself", build: "1", started_at: "T",
      events: [FeedbackEvent(t: 0, screen: "Home")],
      segments: [FeedbackRecordingSegment(file: "recording.mov")])

    #expect(writeFeedbackPauseDurability(in: dir, session: session))

    let pending = pendingInterruptedSessions(root: root, fileManager: .default)
    #expect(pending.map(\.sessionId) == ["s1"])

    let decoded = try JSONDecoder().decode(
      FeedbackSession.self, from: Data(contentsOf: dir.appendingPathComponent("events.json")))
    #expect(decoded.segments?.map(\.file) == ["recording.mov"])
    #expect(decoded.events == [FeedbackEvent(t: 0, screen: "Home")])
  }

  @Test func resumeClearsMarkerAndSessionKeepsRecording() throws {
    let root = try makeRoot()
    let dir = try makeSessionDir(root, "s1")
    let session = FeedbackSession(
      session_id: "s1", app: "dotself", build: "1", started_at: "T", events: [],
      segments: [FeedbackRecordingSegment(file: "recording.mov")])
    writeFeedbackPauseDurability(in: dir, session: session)
    #expect(pendingInterruptedSessions(root: root, fileManager: .default).map(\.sessionId) == ["s1"])

    clearFeedbackPauseDurability(in: dir)

    #expect(pendingInterruptedSessions(root: root, fileManager: .default).isEmpty)
    // The session dir (and its captured segment) is untouched - the session
    // is still open in-process and keeps recording.
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.mov").path))
  }

  /// A second pause (after a resume) overwrites `events.json` with the latest
  /// segments rather than leaving a stale sidecar from the first pause.
  @Test func secondPauseOverwritesSidecarWithLatestSegments() throws {
    let root = try makeRoot()
    let dir = try makeSessionDir(root, "s1")
    let first = FeedbackSession(
      session_id: "s1", app: "dotself", build: "1", started_at: "T", events: [],
      segments: [FeedbackRecordingSegment(file: "recording.mov")])
    writeFeedbackPauseDurability(in: dir, session: first)
    clearFeedbackPauseDurability(in: dir)

    let second = FeedbackSession(
      session_id: "s1", app: "dotself", build: "1", started_at: "T", events: [],
      segments: [
        FeedbackRecordingSegment(file: "recording.mov"),
        FeedbackRecordingSegment(file: "recording-002.mov"),
      ])
    #expect(writeFeedbackPauseDurability(in: dir, session: second))

    let decoded = try JSONDecoder().decode(
      FeedbackSession.self, from: Data(contentsOf: dir.appendingPathComponent("events.json")))
    #expect(decoded.segments?.map(\.file) == ["recording.mov", "recording-002.mov"])
    #expect(pendingInterruptedSessions(root: root, fileManager: .default).map(\.sessionId) == ["s1"])
  }
}
