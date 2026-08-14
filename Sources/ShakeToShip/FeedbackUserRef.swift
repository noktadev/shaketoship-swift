import Foundation

/// Stable, opaque reporter identity attached to every feedback session so the
/// platform can notify the SAME device when its issue is resolved
/// (issues.closed webhook -> inbox message keyed on `user_ref`).
///
/// Resolution order:
///  1. The host's `ShakeToShipConfig.userRef` (a real account/user id) when set.
///  2. A generated `anon-<uuid>` persisted in `UserDefaults` - stable across
///     launches on this install, never leaves the device except inside the
///     feedback payloads. Anonymous apps get resolved-notifications for free.
///
/// The value is capped to the ingest contract's 128-character limit; an
/// over-long host value is truncated rather than dropped so the reporter still
/// gets SOME stable identity.
enum FeedbackUserRef {
  static let defaultsKey = "appfeedback.user_ref"
  static let maxLength = 128

  static func resolve(
    configured: String?,
    defaults: UserDefaults = .standard
  ) -> String {
    if let configured, !configured.isEmpty {
      return String(configured.prefix(maxLength))
    }
    if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
      return existing
    }
    let generated = "anon-\(UUID().uuidString.lowercased())"
    defaults.set(generated, forKey: defaultsKey)
    return generated
  }
}
