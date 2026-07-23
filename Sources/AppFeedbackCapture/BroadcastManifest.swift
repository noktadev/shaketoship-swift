import Foundation

/// Sidecar record for one broadcast capture session.
///
/// The broadcast upload extension is killed without warning (memory cap, user
/// ends the broadcast, OS reclaim), so nothing may be held only in memory: the
/// manifest is the durable handoff between the extension that records and the
/// host app that uploads. Track presence is DECLARED here and never inferred by
/// probing the media file - a truncated `.mov` cannot be trusted to answer
/// "was the mic on?", and opening it to ask would cost memory we do not have.
public struct BroadcastManifest: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable, CaseIterable {
    /// The extension claims to be writing right now. Stale + `.recording`
    /// means it was killed; see `BroadcastContainer.sweep`.
    case recording
    /// Clean stop; `durationSeconds` and `byteCount` are populated.
    case finished
    /// The process died mid-recording. The partial file is still evidence.
    case aborted
    /// Hit `capSeconds` and was finalized by the cap, not by the user.
    case capped
  }

  public var sessionId: String
  public var startedAt: Date
  public var appBundleId: String
  public var sdkVersion: String
  public var hasNarration: Bool
  public var hasAppAudio: Bool
  public var capSeconds: Double
  public var state: State
  /// Populated when the session leaves `.recording`.
  public var durationSeconds: Double?
  /// Size of `capture.mov` at finalization, in bytes.
  public var byteCount: Int?

  public init(
    sessionId: String,
    startedAt: Date,
    appBundleId: String,
    sdkVersion: String,
    hasNarration: Bool,
    hasAppAudio: Bool,
    capSeconds: Double,
    state: State,
    durationSeconds: Double? = nil,
    byteCount: Int? = nil
  ) {
    self.sessionId = sessionId
    self.startedAt = startedAt
    self.appBundleId = appBundleId
    self.sdkVersion = sdkVersion
    self.hasNarration = hasNarration
    self.hasAppAudio = hasAppAudio
    self.capSeconds = capSeconds
    self.state = state
    self.durationSeconds = durationSeconds
    self.byteCount = byteCount
  }

  /// Fixed ISO-8601 dates so a manifest written by the extension decodes
  /// identically in the host app regardless of locale or default strategy.
  /// `.iso8601` emits `.withInternetDateTime` only (no fractional seconds), so
  /// `startedAt` round-trips at whole-second granularity - fine for staleness
  /// math, but worth knowing before relying on sub-second precision.
  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
