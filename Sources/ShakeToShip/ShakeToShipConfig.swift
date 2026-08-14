import Foundation

extension ShakeToShipConfig {
  /// The host app's privacy ceiling: what the SDK is allowed to touch at all,
  /// independent of what the end user later grants or mutes. An empty set is
  /// the inertness floor - `FeedbackGate.shouldAttach` treats it like a nil
  /// config, because a host that ships no bits should get no responder.
  public struct Capabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Permits starting a ReplayKit screen capture at all.
    public static let screenRecording = Capabilities(rawValue: 1 << 0)
    /// Permits the capture to record microphone audio.
    public static let microphone = Capabilities(rawValue: 1 << 1)
    /// Permits attaching an image from the photo library to a report.
    public static let photoLibrary = Capabilities(rawValue: 1 << 2)
    /// Permits free-text notes on a report.
    public static let text = Capabilities(rawValue: 1 << 3)
    /// Every capability. Today's behavior for the two internal apps that do
    /// not pass `capabilities` explicitly.
    public static let all: Capabilities = [.screenRecording, .microphone, .photoLibrary, .text]
  }
}

/// Top-level alias for `ShakeToShipConfig.Capabilities` so a host can spell it
/// either way; both denote the same type.
public typealias Capabilities = ShakeToShipConfig.Capabilities

/// Configuration for the on-demand feedback recorder. Injected at the SwiftUI
/// root via `.shakeToShip(config:)`.
public struct ShakeToShipConfig: Sendable {
  /// Default hard cap on a single recording, in seconds. Exposed so callers
  /// (e.g. a host's safety timer) derive bounds from it instead of duplicating
  /// the constant.
  public static let defaultMaxDuration: TimeInterval = 300

  /// App identifier sent to the collector (e.g. `"dotself"`).
  public let app: String
  /// Base URL of the feedback-collector worker. Presign is `POST {collectorURL}/presign`.
  public let collectorURL: URL
  /// Shared secret sent as the `x-feedback-secret` header.
  public let secret: String
  /// The host app's privacy ceiling. Defaults to `.all`, preserving today's
  /// behavior for call sites that predate this property.
  public let capabilities: Capabilities
  /// Whether the collector should transcribe the recording's audio. Purely a
  /// server-side storage request - it never changes what the SDK captures
  /// (see rule 3 in `FeedbackGate.capturePlan`). Defaults to the wire's v1
  /// default.
  public let transcription: Bool
  /// Hard cap on a single attachment's duration, in seconds. Bounds a video
  /// the user attaches from their photo library, not a live recording.
  public let maxAttachmentDuration: TimeInterval
  /// Hard cap on a single recording, in seconds. Bounds the screen recording
  /// the writer itself produces; the writer cuts off and behaves like a
  /// normal stop when reached.
  public let maxDuration: TimeInterval
  /// Optional funnel seam. The recorder calls this at each flow point; the host
  /// app maps it onto its analytics client. Nil = no emission (today's default,
  /// and the only possibility inside an extension that never builds a config).
  public let onFunnelEvent: (@MainActor @Sendable (FeedbackFunnelEvent) -> Void)?

  /// Optional "stop sending feedback" action offered on the review sheet.
  ///
  /// `nil` (the default, and what every app but Lock In Chinese passes) renders
  /// no such action at all - the sheet is byte-for-byte what it was. Lock In
  /// Chinese collapsed its two Settings feedback rows into one and needs
  /// opt-out to live somewhere the learner already is; without a home, a
  /// TestFlight tester seeded opt-in ON would have no way to stop
  /// shake-to-record.
  public let onOptOut: (@MainActor @Sendable () -> Void)?
  /// Optional stable reporter identity (an account/user id). When nil the SDK
  /// uses a generated per-install anonymous ref (see `FeedbackUserRef`), so
  /// resolved-issue notifications can find their way back to this device
  /// either way. Opaque to the platform; capped at 128 characters.
  public let userRef: String?

  public init(
    app: String,
    collectorURL: URL,
    secret: String,
    capabilities: Capabilities = .all,
    transcription: Bool = true,
    maxAttachmentDuration: TimeInterval = ShakeToShipConfig.defaultMaxDuration,
    maxDuration: TimeInterval = ShakeToShipConfig.defaultMaxDuration,
    onFunnelEvent: (@MainActor @Sendable (FeedbackFunnelEvent) -> Void)? = nil,
    onOptOut: (@MainActor @Sendable () -> Void)? = nil,
    userRef: String? = nil
  ) {
    self.app = app
    self.collectorURL = collectorURL
    self.secret = secret
    self.capabilities = capabilities
    self.transcription = transcription
    self.maxAttachmentDuration = maxAttachmentDuration
    self.maxDuration = maxDuration
    self.onFunnelEvent = onFunnelEvent
    self.onOptOut = onOptOut
    self.userRef = userRef
  }
}
