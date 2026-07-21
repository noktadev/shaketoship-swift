import Foundation

/// Which distribution channel this build is running under. Drives the
/// per-channel activation default: DEBUG and TestFlight builds get the
/// recorder without a remote flag (TestFlight testers are the exact audience
/// shake-to-record exists for), App Store builds keep the two-gate rule
/// (remote flag && Settings opt-in).
public enum FeedbackBuildChannel: Equatable, Sendable {
  case debug
  case testFlight
  case appStore

  /// Pure resolver so both the sandbox-receipt heuristic and the DEBUG
  /// precedence are unit-testable (tests always run in DEBUG, where the live
  /// `#if DEBUG` path can't exercise the Release branches).
  ///
  /// A Release install from TestFlight ships a `sandboxReceipt`; an App Store
  /// install ships a `receipt`. A missing receipt URL resolves to `.appStore`
  /// so an unknown environment fails CLOSED onto the strictest gate.
  public static func resolve(
    isDebugBuild: Bool,
    receiptLastPathComponent: String?
  ) -> FeedbackBuildChannel {
    if isDebugBuild { return .debug }
    return receiptLastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
  }

  /// The live channel for this process.
  public static var current: FeedbackBuildChannel {
    #if DEBUG
    let isDebugBuild = true
    #else
    let isDebugBuild = false
    #endif
    return resolve(
      isDebugBuild: isDebugBuild,
      receiptLastPathComponent: Bundle.main.appStoreReceiptURL?.lastPathComponent
    )
  }
}
