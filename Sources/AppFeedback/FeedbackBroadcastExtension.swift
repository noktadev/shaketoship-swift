import Foundation

/// Finds the host app's ReplayKit broadcast UPLOAD extension.
///
/// `RPSystemBroadcastPickerView.preferredExtension` wants a bundle id. Deriving
/// it by string surgery on the app's own bundle id (LiveKit appends
/// `.broadcast`) only works for hosts that happen to use that suffix, and fails
/// silently - the picker just lists every broadcast extension on the device
/// instead. Reading the shipped `PlugIns` directory answers the question from
/// what is actually embedded in this build.
///
/// The setup-UI sibling is deliberately excluded: a ReplayKit extension ships
/// as a pair, and pointing `preferredExtension` at the setup-UI appex produces
/// a picker that appears to work and records nothing.
public enum FeedbackBroadcastExtension {
  /// `NSExtensionPointIdentifier` of a broadcast upload extension - the process
  /// that receives sample buffers. Its sibling, `...-setupui`, only renders the
  /// pre-broadcast sheet.
  public static let uploadPointIdentifier = "com.apple.broadcast-services-upload"

  /// Bundle id of the embedded broadcast upload extension, or nil when this
  /// build has none (the SDK is linked but `shaketoship init` was never run).
  /// Nil is a legitimate answer, not an error: the picker still works without a
  /// `preferredExtension`, it just shows every broadcast target on the device.
  public static func discoverInMainBundle(_ bundle: Bundle = .main) -> String? {
    discover(inPlugInsAt: bundle.builtInPlugInsURL)
  }

  /// - Parameter plugInsURL: A `PlugIns` directory. Nil (a bundle that embeds
  ///   no extensions at all) and a missing directory both answer nil.
  /// - Returns: The lowest bundle id among the upload extensions found, so a
  ///   host that somehow embeds two gets a stable answer instead of one that
  ///   depends on directory enumeration order.
  public static func discover(
    inPlugInsAt plugInsURL: URL?, fileManager: FileManager = .default
  ) -> String? {
    guard let plugInsURL,
      let entries = try? fileManager.contentsOfDirectory(
        at: plugInsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return nil }

    return
      entries
      .filter { $0.pathExtension == "appex" }
      .compactMap { uploadExtensionBundleId(at: $0) }
      .min()
  }

  /// Bundle id of `appex` when - and only when - its `Info.plist` declares the
  /// broadcast upload extension point.
  private static func uploadExtensionBundleId(at appex: URL) -> String? {
    guard let data = try? Data(contentsOf: appex.appendingPathComponent("Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let bundleId = info["CFBundleIdentifier"] as? String,
      let extensionInfo = info["NSExtension"] as? [String: Any],
      extensionInfo["NSExtensionPointIdentifier"] as? String == uploadPointIdentifier
    else { return nil }
    return bundleId
  }
}
