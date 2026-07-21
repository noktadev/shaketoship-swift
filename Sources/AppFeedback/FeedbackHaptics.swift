#if canImport(UIKit)
import UIKit

/// Thin haptic helper for the feedback recorder. DEBUG+device paths call these
/// at record start/stop and on the upload-result toast. On the simulator every
/// method is a no-op. NOT unit tested (device-only UIKit). No analytics.
@MainActor
enum FeedbackHaptics {
  static func impact() {
    #if !targetEnvironment(simulator)
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    #endif
  }

  static func success() {
    #if !targetEnvironment(simulator)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
  }

  static func warning() {
    #if !targetEnvironment(simulator)
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
    #endif
  }

  static func light() {
    #if !targetEnvironment(simulator)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    #endif
  }
}
#endif
