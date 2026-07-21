import Foundation

/// Configuration for the on-demand feedback recorder. Injected at the SwiftUI
/// root via `.feedbackRecorder(config:)`.
public struct FeedbackConfig: Sendable {
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
  /// Hard cap on a single recording. The writer cuts off and behaves like a
  /// normal stop when reached.
  public let maxDuration: TimeInterval
  /// Optional funnel seam. The recorder calls this at each flow point; the host
  /// app maps it onto its analytics client. Nil = no emission (today's default,
  /// and the only possibility inside an extension that never builds a config).
  public let onFunnelEvent: (@MainActor @Sendable (FeedbackFunnelEvent) -> Void)?

  public init(
    app: String,
    collectorURL: URL,
    secret: String,
    maxDuration: TimeInterval = FeedbackConfig.defaultMaxDuration,
    onFunnelEvent: (@MainActor @Sendable (FeedbackFunnelEvent) -> Void)? = nil
  ) {
    self.app = app
    self.collectorURL = collectorURL
    self.secret = secret
    self.maxDuration = maxDuration
    self.onFunnelEvent = onFunnelEvent
  }
}
