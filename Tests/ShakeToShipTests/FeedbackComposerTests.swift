import Foundation
import Testing

@testable import ShakeToShip

/// Host-side (UIKit-free) proof of the composer's rules. The sheet itself stays
/// device-only UI, exactly as `FeedbackReviewSheet` was - so every rule the
/// sheet obeys lives in a pure type that compiles and runs on macOS, the same
/// pattern `FeedbackGate` and `FeedbackTapFormatting` already use.
@Suite struct FeedbackComposerSendRuleTests {
  private static let clip = URL(fileURLWithPath: "/tmp/recording.mov")
  private static let shot = URL(fileURLWithPath: "/tmp/shot.jpg")

  /// The SDK never sends an empty report.
  @Test func emptyComposerCannotSend() {
    #expect(FeedbackComposerRules.sendEnabled(media: [], note: "") == false)
  }

  /// Whitespace is not a note. A user who tapped into the field and typed a
  /// space has still written nothing, and "non-blank" is the plan's word.
  @Test func whitespaceOnlyNoteCannotSend() {
    #expect(FeedbackComposerRules.sendEnabled(media: [], note: "   ") == false)
    #expect(FeedbackComposerRules.sendEnabled(media: [], note: "\n\t ") == false)
  }

  @Test func aNoteAloneCanSend() {
    #expect(FeedbackComposerRules.sendEnabled(media: [], note: "the tab bar vanished") == true)
  }

  @Test func mediaAloneCanSend() {
    #expect(FeedbackComposerRules.sendEnabled(media: [.recorded(Self.clip)], note: "") == true)
    #expect(
      FeedbackComposerRules.sendEnabled(media: [.picked(Self.shot, .image)], note: "  ") == true)
  }

  @Test func mediaAndNoteTogetherCanSend() {
    #expect(
      FeedbackComposerRules.sendEnabled(media: [.recorded(Self.clip)], note: "here") == true)
  }
}

@Suite struct FeedbackComposerAffordanceTests {
  /// No Attach button without `.photoLibrary`.
  @Test func attachNeedsThePhotoLibraryCapability() {
    #expect(FeedbackComposerRules.showsAttach(capabilities: .all, mediaCount: 0) == true)
    #expect(
      FeedbackComposerRules.showsAttach(
        capabilities: [.screenRecording, .microphone, .text], mediaCount: 0) == false)
  }

  /// The Attach button also disappears once the basket is full: three is the
  /// cap on the composer's media, not on one picker session.
  @Test func attachDisappearsAtTheItemCap() {
    #expect(FeedbackComposerRules.showsAttach(capabilities: .all, mediaCount: 2) == true)
    #expect(FeedbackComposerRules.showsAttach(capabilities: .all, mediaCount: 3) == false)
  }

  /// No note field without `.text`.
  @Test func noteFieldNeedsTheTextCapability() {
    #expect(FeedbackComposerRules.showsNoteField(capabilities: .all) == true)
    #expect(FeedbackComposerRules.showsNoteField(capabilities: .text) == true)
    #expect(
      FeedbackComposerRules.showsNoteField(
        capabilities: [.screenRecording, .microphone, .photoLibrary]) == false)
  }

  /// No Record action without `.screenRecording`.
  @Test func recordActionNeedsTheScreenRecordingCapability() {
    #expect(FeedbackComposerRules.showsRecordAction(capabilities: .all) == true)
    #expect(
      FeedbackComposerRules.showsRecordAction(capabilities: [.photoLibrary, .text]) == false)
  }

  /// Only a picked item may leave the strip. Removing the recorded clip would
  /// take the thumbnail away and leave `recording.mov` on disk for the
  /// uploader to send anyway - a user who believes they unsent a video and
  /// did not. Discard is how a recording is unsent.
  @Test func onlyPickedItemsCanBeRemoved() {
    let clip = URL(fileURLWithPath: "/tmp/recording.mov")
    let shot = URL(fileURLWithPath: "/tmp/shot.jpg")
    #expect(FeedbackComposerRules.showsRemove(for: .picked(shot, .image)) == true)
    #expect(FeedbackComposerRules.showsRemove(for: .recorded(clip)) == false)
  }

  /// The picker may only ever offer the slots that are still free, so a
  /// selection can never overshoot the cap and then be trimmed after the fact.
  @Test func pickerLimitIsWhateverIsLeft() {
    #expect(FeedbackComposerRules.remainingSelectionLimit(mediaCount: 0) == 3)
    #expect(FeedbackComposerRules.remainingSelectionLimit(mediaCount: 1) == 2)
    #expect(FeedbackComposerRules.remainingSelectionLimit(mediaCount: 3) == 0)
    // Defensive: never negative, whatever the caller passes.
    #expect(FeedbackComposerRules.remainingSelectionLimit(mediaCount: 9) == 0)
  }
}

/// Where a shake lands. A host that cannot record must not be asked "Record &
/// report" - the prompt exists to ask about recording, so with no recording to
/// offer the shake opens the composer directly instead of adding a dead tap.
@Suite struct FeedbackShakeDestinationTests {
  @Test func recordingCapableHostsGetThePrompt() {
    #expect(FeedbackComposerRules.shakeDestination(capabilities: .all) == .prompt)
    #expect(FeedbackComposerRules.shakeDestination(capabilities: .screenRecording) == .prompt)
  }

  @Test func writeOnlyHostsGoStraightToTheComposer() {
    #expect(FeedbackComposerRules.shakeDestination(capabilities: .text) == .composer)
    #expect(FeedbackComposerRules.shakeDestination(capabilities: .photoLibrary) == .composer)
    #expect(
      FeedbackComposerRules.shakeDestination(capabilities: [.photoLibrary, .text]) == .composer)
  }

  /// `.microphone` alone composes nothing and records nothing: it is a
  /// modifier on a capture that this host may not start. A shake offers
  /// nothing rather than opening an empty composer that can never send.
  @Test func aHostWithNothingToComposeOffersNothing() {
    #expect(FeedbackComposerRules.shakeDestination(capabilities: .microphone) == .none)
    #expect(FeedbackComposerRules.shakeDestination(capabilities: []) == .none)
  }
}

@Suite struct FeedbackMediaItemTests {
  private static let clip = URL(fileURLWithPath: "/tmp/recording.mov")
  private static let shot = URL(fileURLWithPath: "/tmp/shot.jpg")
  private static let movie = URL(fileURLWithPath: "/tmp/clip.mov")

  @Test func everyItemExposesItsURL() {
    #expect(FeedbackMediaItem.recorded(Self.clip).url == Self.clip)
    #expect(FeedbackMediaItem.picked(Self.shot, .image).url == Self.shot)
  }

  /// A recorded item is a video by construction - there is no other kind of
  /// screen capture - so callers never have to special-case it.
  @Test func aRecordedItemIsAVideo() {
    #expect(FeedbackMediaItem.recorded(Self.clip).kind == .video)
    #expect(FeedbackMediaItem.picked(Self.shot, .image).kind == .image)
    #expect(FeedbackMediaItem.picked(Self.movie, .video).kind == .video)
  }

  /// `Identifiable` drives SwiftUI's `ForEach` over the media strip; two
  /// different files must never collide onto one id.
  @Test func idsAreDistinctPerFile() {
    #expect(FeedbackMediaItem.recorded(Self.clip).id != FeedbackMediaItem.picked(Self.shot, .image).id)
    #expect(FeedbackMediaItem.picked(Self.shot, .image).id == FeedbackMediaItem.picked(Self.shot, .image).id)
  }

  /// The recorded clip is the session's own `recording.mov` and uploads under
  /// that name; a picked item uploads as `attachment-N`. Chunk H reads these
  /// names, so they are pinned here rather than spelled inline twice.
  @Test func fileNamesMatchTheWireContract() {
    #expect(FeedbackAttachmentNaming.recordingFile == "recording.mov")
    #expect(FeedbackAttachmentNaming.noteFile == "note.txt")
    #expect(FeedbackAttachmentNaming.attachmentFile(index: 0, kind: .image) == "attachment-0.jpg")
    #expect(FeedbackAttachmentNaming.attachmentFile(index: 2, kind: .video) == "attachment-2.mov")
  }
}

@Suite struct FeedbackAttachmentBoundsTests {
  private func image(bytes: Int = 100_000) -> FeedbackAttachmentCandidate {
    FeedbackAttachmentCandidate(kind: .image, durationSeconds: nil, byteCount: bytes)
  }

  private func video(seconds: TimeInterval, bytes: Int = 100_000) -> FeedbackAttachmentCandidate {
    FeedbackAttachmentCandidate(kind: .video, durationSeconds: seconds, byteCount: bytes)
  }

  @Test func aNormalImageIsAdmitted() {
    #expect(
      FeedbackAttachmentBounds.admit(
        image(), existingCount: 0, existingBytes: 0, maxAttachmentDuration: 300) == nil)
  }

  /// The 3-item cap, at the admission seam rather than only in the picker's
  /// `selectionLimit`: the recorded clip already occupies a slot, and the
  /// interrupted-session offer opens the composer with it in place.
  @Test func theFourthItemIsRejected() {
    #expect(
      FeedbackAttachmentBounds.admit(
        image(), existingCount: 2, existingBytes: 0, maxAttachmentDuration: 300) == nil)
    #expect(
      FeedbackAttachmentBounds.admit(
        image(), existingCount: 3, existingBytes: 0, maxAttachmentDuration: 300)
        == .tooManyItems(limit: 3))
  }

  /// A video past `maxAttachmentDuration` is rejected with an inline message.
  @Test func anOverlongVideoIsRejected() {
    #expect(
      FeedbackAttachmentBounds.admit(
        video(seconds: 299), existingCount: 0, existingBytes: 0, maxAttachmentDuration: 300) == nil)
    #expect(
      FeedbackAttachmentBounds.admit(
        video(seconds: 301), existingCount: 0, existingBytes: 0, maxAttachmentDuration: 300)
        == .videoTooLong(limitSeconds: 300))
  }

  /// The host's `maxAttachmentDuration` is what bounds it - not a constant
  /// baked into the SDK. A host that allows 10s rejects an 11s clip.
  @Test func theDurationLimitComesFromTheHostConfig() {
    #expect(
      FeedbackAttachmentBounds.admit(
        video(seconds: 11), existingCount: 0, existingBytes: 0, maxAttachmentDuration: 10)
        == .videoTooLong(limitSeconds: 10))
    #expect(
      FeedbackAttachmentBounds.admit(
        video(seconds: 11), existingCount: 0, existingBytes: 0, maxAttachmentDuration: 600) == nil)
  }

  /// A video whose duration could not be read is refused, not waved through:
  /// an unbounded clip is exactly what the duration cap exists to stop.
  @Test func aVideoWithNoReadableDurationIsRejected() {
    let unknown = FeedbackAttachmentCandidate(kind: .video, durationSeconds: nil, byteCount: 1)
    #expect(
      FeedbackAttachmentBounds.admit(
        unknown, existingCount: 0, existingBytes: 0, maxAttachmentDuration: 300) == .unreadable)
  }

  /// The byte cap is on the TOTAL, not per item: three items each under the
  /// cap can still add up past it.
  @Test func theByteCapIsOnTheTotal() {
    let cap = FeedbackAttachmentBounds.maxTotalBytes
    #expect(
      FeedbackAttachmentBounds.admit(
        image(bytes: cap / 2), existingCount: 1, existingBytes: cap / 2,
        maxAttachmentDuration: 300) == nil)
    #expect(
      FeedbackAttachmentBounds.admit(
        image(bytes: cap / 2 + 1), existingCount: 1, existingBytes: cap / 2,
        maxAttachmentDuration: 300) == .tooLarge(limitBytes: cap))
  }

  /// Every rejection carries user-facing copy - the plan's "rejected with an
  /// inline message". A blank message is a silent failure on device.
  @Test func everyRejectionHasAMessage() {
    let rejections: [FeedbackAttachmentRejection] = [
      .tooManyItems(limit: 3), .videoTooLong(limitSeconds: 300),
      .tooLarge(limitBytes: 1024), .unreadable,
    ]
    for rejection in rejections {
      #expect(rejection.message.isEmpty == false)
    }
  }

  /// The item cap is checked before the duration: a fourth item is refused for
  /// being a fourth item, whatever it contains.
  @Test func theItemCapWinsOverTheDurationCap() {
    #expect(
      FeedbackAttachmentBounds.admit(
        video(seconds: 9_999), existingCount: 3, existingBytes: 0, maxAttachmentDuration: 300)
        == .tooManyItems(limit: 3))
  }
}

/// The composer's output is what chunk H uploads. A result that loses the note
/// or reorders the media is a silent data loss, so the mapping from composer
/// state to on-disk file names is pinned here.
@Suite struct FeedbackComposerResultTests {
  private static let clip = URL(fileURLWithPath: "/tmp/recording.mov")
  private static let shot = URL(fileURLWithPath: "/tmp/shot.jpg")
  private static let movie = URL(fileURLWithPath: "/tmp/clip.mov")

  @Test func pickedItemsAreNumberedFromZeroIgnoringTheRecording() {
    let plan = FeedbackComposerRules.attachmentPlan(media: [
      .recorded(Self.clip), .picked(Self.shot, .image), .picked(Self.movie, .video),
    ])
    #expect(plan.map(\.fileName) == ["attachment-0.jpg", "attachment-1.mov"])
    #expect(plan.map(\.source) == [Self.shot, Self.movie])
  }

  /// A composer with no recording still numbers its attachments from zero.
  @Test func aTextAndImageReportNumbersFromZero() {
    let plan = FeedbackComposerRules.attachmentPlan(media: [.picked(Self.shot, .image)])
    #expect(plan.map(\.fileName) == ["attachment-0.jpg"])
  }

  @Test func aRecordingOnlyReportHasNoAttachments() {
    #expect(FeedbackComposerRules.attachmentPlan(media: [.recorded(Self.clip)]).isEmpty)
  }

  /// The note is trimmed before it is written: trailing whitespace the user
  /// never sees must not become a `note.txt` that reads as content, and a
  /// blank note must produce no file at all (chunk H uploads what exists).
  @Test func onlyANonBlankNoteBecomesAFile() {
    #expect(FeedbackComposerRules.noteFileContents(note: "  hey  ") == "hey")
    #expect(FeedbackComposerRules.noteFileContents(note: "   ") == nil)
    #expect(FeedbackComposerRules.noteFileContents(note: "") == nil)
  }
}

/// The real seam: what a composed report leaves ON DISK for chunk H's uploader
/// to find. A plan that names the right files but writes the wrong ones is
/// exactly the defect a returned-value assertion cannot see, so every
/// expectation here reads the session directory back.
@Suite struct FeedbackComposedReportOnDiskTests {
  private func session() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("sts-composer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func file(_ dir: URL, _ name: String, bytes: String = "x") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(bytes.utf8).write(to: url)
    return url
  }

  private func names(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
  }

  @Test func attachmentsLandUnderTheirWireNames() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = dir.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let shot = try file(staging, "abc.jpg", bytes: "image-bytes")
    let clip = try file(staging, "def.mov", bytes: "video-bytes")

    let ok = persistComposedReport(
      FeedbackComposerResult(
        media: [.picked(shot, .image), .picked(clip, .video)], note: "broke here"),
      in: dir)

    #expect(ok)
    #expect(names(in: dir) == ["attachment-0.jpg", "attachment-1.mov", "note.txt", "staging"])
    #expect(
      try String(contentsOf: dir.appendingPathComponent("attachment-1.mov"), encoding: .utf8)
        == "video-bytes")
    #expect(
      try String(contentsOf: dir.appendingPathComponent("note.txt"), encoding: .utf8)
        == "broke here")
  }

  /// A recorded clip is already `recording.mov` in this directory. It must not
  /// be copied onto itself as `attachment-0.mov` - that would upload and meter
  /// the same video twice.
  @Test func theRecordedClipIsNotRewrittenAsAnAttachment() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }
    let recording = try file(dir, "recording.mov", bytes: "capture")

    persistComposedReport(
      FeedbackComposerResult(media: [.recorded(recording)], note: ""), in: dir)

    #expect(names(in: dir) == ["recording.mov"])
  }

  /// A blank note writes no file at all: chunk H uploads the files a session
  /// has, so an empty `note.txt` would become an empty note on the report.
  @Test func aBlankNoteWritesNoFile() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }

    persistComposedReport(FeedbackComposerResult(media: [], note: "  \n "), in: dir)

    #expect(names(in: dir).isEmpty)
  }

  /// A second send (first upload failed, the user tried again) must not throw
  /// on the file it already wrote and silently drop the attachment.
  @Test func aResentReportOverwritesRatherThanFails() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = dir.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let shot = try file(staging, "abc.jpg", bytes: "first")

    persistComposedReport(FeedbackComposerResult(media: [.picked(shot, .image)], note: ""), in: dir)
    try Data("second".utf8).write(to: shot)
    let ok = persistComposedReport(
      FeedbackComposerResult(media: [.picked(shot, .image)], note: ""), in: dir)

    #expect(ok)
    #expect(
      try String(contentsOf: dir.appendingPathComponent("attachment-0.jpg"), encoding: .utf8)
        == "second")
  }

  /// A missing source is reported, not swallowed: the caller surfaces it
  /// rather than uploading a report the user believes carries an attachment.
  @Test func aMissingSourceIsReported() throws {
    let dir = try session()
    defer { try? FileManager.default.removeItem(at: dir) }
    let ghost = dir.appendingPathComponent("staging/gone.jpg")

    let ok = persistComposedReport(
      FeedbackComposerResult(media: [.picked(ghost, .image)], note: "still says this"), in: dir)

    #expect(ok == false)
    // The note still lands - one broken attachment must not lose the words.
    #expect(names(in: dir) == ["note.txt"])
  }
}
