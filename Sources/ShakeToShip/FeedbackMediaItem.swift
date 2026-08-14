import Foundation

/// What a piece of composer media is. Deliberately only two cases: the wire
/// carries `attachment-N.jpg` or `attachment-N.mov` and nothing else, so a
/// third kind would need a wire change, not just an enum case.
public enum FeedbackMediaKind: String, Sendable, Equatable, Hashable, Codable {
  case image
  case video

  /// The extension the file lands on disk (and on the wire) with. Images are
  /// always re-encoded to JPEG on the way in, so a HEIC from the library is a
  /// `.jpg` by the time it reaches a `FeedbackMediaItem`.
  public var fileExtension: String {
    switch self {
    case .image: return "jpg"
    case .video: return "mov"
    }
  }
}

/// One item in the composer's media strip. The composer holds 0 to 3 of these,
/// filled by any mix of entry points: the recorder drops a `.recorded` clip in,
/// the photo picker adds `.picked` items.
public enum FeedbackMediaItem: Identifiable, Sendable, Equatable {
  /// This session's own screen capture, already finalized in the session dir.
  case recorded(URL)
  /// An item copied out of the photo library into the session's staging dir.
  case picked(URL, FeedbackMediaKind)

  /// Where the bytes are right now. For `.recorded` that is the session dir;
  /// for `.picked` it is the staging copy the picker wrote.
  public var url: URL {
    switch self {
    case let .recorded(url): return url
    case let .picked(url, _): return url
    }
  }

  /// A screen capture is a video by construction - ReplayKit produces nothing
  /// else - so no caller has to special-case the recorded slot.
  public var kind: FeedbackMediaKind {
    switch self {
    case .recorded: return .video
    case let .picked(_, kind): return kind
    }
  }

  /// The recorded clip uploads as `recording.mov`, a picked one as
  /// `attachment-N`. That difference outlives the composer, so it is asked of
  /// the item rather than re-derived from a URL somewhere downstream.
  public var isRecorded: Bool {
    if case .recorded = self { return true }
    return false
  }

  /// Keyed on the file URL: SwiftUI's `ForEach` over the strip must not
  /// collapse two different files onto one row, and two items can never share
  /// a URL (the picker writes a fresh staging name per selection).
  public var id: URL { url }
}

/// The file names the composer writes into a session dir. Chunk H's uploader
/// reads the same names, so they are stated once here instead of being spelled
/// inline on both sides of that seam.
public enum FeedbackAttachmentNaming {
  /// The session's own screen capture. Unchanged from before the composer -
  /// it is now optional in fact as well as in code.
  public static let recordingFile = "recording.mov"
  /// The composer's free text. A file, not a manifest field, so nothing puts a
  /// length ceiling on it.
  public static let noteFile = "note.txt"

  /// `attachment-{0,1,2}.{jpg,mov}`. The index numbers the PICKED items only,
  /// from zero, in composer order.
  public static func attachmentFile(index: Int, kind: FeedbackMediaKind) -> String {
    "attachment-\(index).\(kind.fileExtension)"
  }
}

/// A candidate the picker produced, reduced to the three facts the bounds care
/// about. Keeping the decision over this struct rather than over a
/// `PHPickerResult` is what lets the caps be proven host-side, with no photo
/// library and no device.
public struct FeedbackAttachmentCandidate: Sendable, Equatable {
  public let kind: FeedbackMediaKind
  /// Video length in seconds. Always nil for an image; nil for a video means
  /// the duration could not be read, which is a rejection, not a pass.
  public let durationSeconds: TimeInterval?
  public let byteCount: Int

  public init(kind: FeedbackMediaKind, durationSeconds: TimeInterval?, byteCount: Int) {
    self.kind = kind
    self.durationSeconds = durationSeconds
    self.byteCount = byteCount
  }
}

/// Why a candidate was refused. Each case carries the bound it broke so the
/// inline message can name a number rather than say "too big".
public enum FeedbackAttachmentRejection: Equatable, Sendable {
  case tooManyItems(limit: Int)
  case videoTooLong(limitSeconds: TimeInterval)
  case tooLarge(limitBytes: Int)
  /// A video whose duration could not be read. Refused rather than admitted:
  /// an unmeasured clip is precisely what the duration cap exists to stop, and
  /// an attached video is metered.
  case unreadable

  /// User-facing copy, shown inline under the media strip. Never a raw error.
  public var message: String {
    switch self {
    case let .tooManyItems(limit):
      return "You can attach up to \(limit) items."
    case let .videoTooLong(limitSeconds):
      return "That video is longer than \(Int(limitSeconds.rounded())) seconds. Trim it and try again."
    case let .tooLarge(limitBytes):
      return "That's over the \(limitBytes / (1024 * 1024)) MB limit for one report."
    case .unreadable:
      return "That item couldn't be read. Try a different one."
    }
  }
}

/// The bounds every attachment is admitted through. Pure, so the caps are
/// tested without a photo library - and stated once, so the picker's
/// `selectionLimit` and the admission check cannot drift apart.
public enum FeedbackAttachmentBounds {
  /// Total items the composer holds, the recorded clip included.
  public static let maxItems = 3
  /// Longest edge an attached image is re-encoded down to, in pixels.
  public static let maxImageDimension: Double = 1920
  /// JPEG quality for that re-encode.
  public static let jpegCompressionQuality: Double = 0.8
  /// Total bytes across every attachment in one report. Three full-length
  /// videos would otherwise drain a free tier's whole month in one send.
  public static let maxTotalBytes = 40 * 1024 * 1024

  /// Returns nil when the candidate is admitted, or the reason it is not.
  ///
  /// Order matters and is asserted: the item cap is checked first, so a fourth
  /// item is refused for being a fourth item whatever it contains.
  public static func admit(
    _ candidate: FeedbackAttachmentCandidate,
    existingCount: Int,
    existingBytes: Int,
    maxAttachmentDuration: TimeInterval
  ) -> FeedbackAttachmentRejection? {
    guard existingCount < maxItems else { return .tooManyItems(limit: maxItems) }
    if candidate.kind == .video {
      guard let duration = candidate.durationSeconds else { return .unreadable }
      guard duration <= maxAttachmentDuration else {
        return .videoTooLong(limitSeconds: maxAttachmentDuration)
      }
    }
    guard existingBytes + candidate.byteCount <= maxTotalBytes else {
      return .tooLarge(limitBytes: maxTotalBytes)
    }
    return nil
  }
}
