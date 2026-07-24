import Foundation

/// Everything the broadcast upload extension needs to know, resolved from its
/// own `Info.plist` at launch.
///
/// The extension has no UI, no user, and no network round trip it can afford:
/// this is the only configuration channel it has. `shaketoship init` writes
/// these keys into the generated target.
///
/// ```xml
/// <key>AppFeedbackHostBundleId</key>
/// <string>com.example.app</string>
/// <key>AppFeedbackCapSeconds</key>
/// <integer>600</integer>
/// ```
public struct FeedbackBroadcastConfiguration: Equatable, Sendable {
  /// Info.plist key for the HOST app's bundle id - not the extension's own.
  /// The App Group both processes share is derived from it
  /// (`BroadcastContainer.appGroupIdentifier(hostBundleId:)`), so it has to
  /// name the app, and there is nothing sane to fall back to if it is missing.
  public static let hostBundleIdKey = "AppFeedbackHostBundleId"
  /// Info.plist key for the recording ceiling in seconds.
  public static let capSecondsKey = "AppFeedbackCapSeconds"

  /// Ten minutes. This is the ceiling the writer stops feeding samples at, not
  /// an entitlement decision - the host app writing a plan-derived ceiling into
  /// the App Group is `cap-enforcement`, a later chunk.
  public static let defaultCapSeconds: Double = 600

  /// Version of the capture SDK itself, stamped into every manifest so the
  /// server can attribute a file it cannot parse to the build that wrote it.
  /// Bumped by hand alongside this package.
  public static let sdkVersion = "0.1.0"

  public let hostBundleId: String
  public let sdkVersion: String
  public let capSeconds: Double

  public init(
    hostBundleId: String,
    sdkVersion: String = FeedbackBroadcastConfiguration.sdkVersion,
    capSeconds: Double = FeedbackBroadcastConfiguration.defaultCapSeconds
  ) {
    self.hostBundleId = hostBundleId
    self.sdkVersion = sdkVersion
    self.capSeconds = capSeconds
  }

  /// `nil` when the host bundle id is missing or not a non-empty string. The
  /// caller must then fail the broadcast outright: minting a session against a
  /// guessed App Group would record perfectly into a container the host app
  /// never reads.
  ///
  /// An absent, unparseable, or non-positive cap falls back to
  /// `defaultCapSeconds` instead of failing - a plist typo there costs a
  /// too-long recording, while treating it as authoritative would make the sink
  /// refuse the very first buffer and produce nothing at all.
  public init?(infoDictionary: [String: Any]) {
    guard let hostBundleId = infoDictionary[Self.hostBundleIdKey] as? String,
      !hostBundleId.isEmpty
    else { return nil }
    self.hostBundleId = hostBundleId
    self.sdkVersion = Self.sdkVersion
    // Plists carry numbers as NSNumber and hand-edited ones often carry them as
    // <string>, so accept both shapes rather than silently defaulting.
    let raw = infoDictionary[Self.capSecondsKey]
    let parsed = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init)
    if let parsed, parsed > 0 {
      self.capSeconds = parsed
    } else {
      self.capSeconds = Self.defaultCapSeconds
    }
  }

  /// Resolves from a bundle's Info.plist - `Bundle.main` inside the extension
  /// process is the extension's own bundle.
  public init?(bundle: Bundle) {
    self.init(infoDictionary: bundle.infoDictionary ?? [:])
  }
}
