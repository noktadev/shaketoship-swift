import Foundation

/// Whether the current device has a Dynamic Island, deciding which in-app
/// recording indicator the modifier shows (#474): island devices rely on the
/// Live Activity ALONE (no in-app chrome) as long as one is running; non-island
/// devices always get the slim top recording bar.
///
/// There is no public "has Dynamic Island" API, so this maps the hardware model
/// identifier against an explicit ALLOWLIST of known island phones. A major
/// version alone is NOT a reliable signal: iPhone 16e is `iPhone17,5` yet has no
/// Dynamic Island, even though its 16-family siblings (`iPhone17,1...4`) do. The
/// rule therefore fails SAFE - any identifier not in the allowlist (a pre-island
/// phone, a non-island model in an island generation like the 16e, a non-phone,
/// or a phone newer than this table) is treated as NOT having an island, so the
/// modifier shows the visible recording bar rather than risk leaving a recording
/// with no on-screen indicator or stop affordance. Pure (identifier in, Bool
/// out) so it is unit-tested without a device.
public enum FeedbackDeviceCapability {
  /// The running device's decision, read from `utsname.machine`.
  public static var current: Bool { hasDynamicIsland(identifier: machineIdentifier()) }

  /// Model identifiers of every iPhone known to ship a Dynamic Island. Anything
  /// not listed fails safe to "no island" (show the bar). NOTE: `iPhone17,5`
  /// (iPhone 16e) is deliberately absent - it has no Dynamic Island despite its
  /// island-generation siblings.
  private static let islandModels: Set<String> = [
    // iPhone 14 Pro / 14 Pro Max
    "iPhone15,2", "iPhone15,3",
    // iPhone 15 / 15 Plus / 15 Pro / 15 Pro Max
    "iPhone15,4", "iPhone15,5", "iPhone16,1", "iPhone16,2",
    // iPhone 16 / 16 Plus / 16 Pro / 16 Pro Max (16e = iPhone17,5 is NOT here)
    "iPhone17,3", "iPhone17,4", "iPhone17,1", "iPhone17,2",
  ]

  /// Pure model-identifier decision. See the type doc for the fail-safe rule:
  /// only explicitly-known island phones return true; everything else (unknown
  /// future phones included) returns false so the recording bar is shown.
  public static func hasDynamicIsland(identifier: String) -> Bool {
    islandModels.contains(identifier)
  }

  private static func machineIdentifier() -> String {
    var info = utsname()
    uname(&info)
    let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
      let bytes = raw.prefix { $0 != 0 }
      return String(decoding: bytes, as: UTF8.self)
    }
    return machine
  }
}
