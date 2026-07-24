import Foundation

/// What `requestActivation()` actually managed to do. Returned rather than
/// swallowed so a caller can tell "the system sheet is up" from "nothing
/// happened" - the failure mode this feature cannot afford is a tap that looks
/// like it worked.
public enum BroadcastActivationOutcome: Equatable, Sendable {
  /// The picker's own button was pressed programmatically; iOS is showing the
  /// broadcast sheet. Still only a request: the user has to confirm, and the
  /// system enforces its own 3-second countdown afterwards.
  case pressedProgrammatically
  /// The private selector was unavailable, so the raw picker view was put on
  /// screen instead. The user has one extra tap to make.
  case presentedPicker
  /// Neither path worked - no picker on this platform, or nowhere to present
  /// it. The caller must surface this; there is no broadcast coming.
  case unavailable
}

/// The system broadcast picker, reduced to the four things activation needs.
///
/// Exists so the activation policy is testable off-device: the concrete
/// implementation is `RPSystemBroadcastPickerView`, which is iOS-only. The
/// policy itself - configure, then press if we can, else show the real view -
/// is ordinary code and is tested for real.
@MainActor
public protocol BroadcastPicker: AnyObject {
  /// Whether the picker responds to the private `buttonPressed:` selector.
  var respondsToButtonPressed: Bool { get }
  func configure(preferredExtension: String?, showsMicrophoneButton: Bool)
  /// Only called when `respondsToButtonPressed` is true.
  func pressButton()
  /// Puts the picker view itself on screen. Returns false when there is
  /// nowhere to put it.
  func presentRawPicker() -> Bool
}

public enum FeedbackBroadcastActivation {
  /// Configures `picker` and asks it to open the system broadcast sheet.
  ///
  /// `buttonPressed:` is a private selector. It ships in LiveKit's
  /// `client-sdk-swift`, which is live on the App Store, so it is proven
  /// through review - but "proven through review" is not "guaranteed to exist
  /// next release". Hence the `responds(to:)` guard AND a fallback that puts
  /// the real picker on screen: if Apple removes the selector, the feature
  /// costs the user one extra tap instead of breaking.
  ///
  /// The microphone toggle is always offered. Narration is the point of
  /// cross-app capture - the reviewer talks while browsing - so a picker
  /// without the mic button would ship the feature with its payload removed.
  @MainActor
  @discardableResult
  public static func activate(
    picker: BroadcastPicker, preferredExtension: String?
  ) -> BroadcastActivationOutcome {
    // Configure BEFORE pressing: pressing first opens the sheet against a
    // picker with no `preferredExtension` and no mic button.
    picker.configure(preferredExtension: preferredExtension, showsMicrophoneButton: true)

    guard picker.respondsToButtonPressed else {
      return picker.presentRawPicker() ? .presentedPicker : .unavailable
    }
    picker.pressButton()
    return .pressedProgrammatically
  }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
import ReplayKit
import UIKit

/// `RPSystemBroadcastPickerView` behind the `BroadcastPicker` seam.
///
/// Not exercised by the test suite - it is UIKit + ReplayKit, and ReplayKit
/// broadcast is non-functional in the Simulator anyway. Its two behaviours
/// (does `buttonPressed:` still exist, does the fallback view render) are
/// device UAT items.
@MainActor
public final class SystemBroadcastPicker: BroadcastPicker {
  private static let buttonPressedSelector = NSSelectorFromString("buttonPressed:")
  /// Sized like a standard system button so the fallback path renders
  /// something tappable rather than a zero-size view.
  private let view = RPSystemBroadcastPickerView(
    frame: CGRect(x: 0, y: 0, width: 60, height: 60))
  private let present: (UIView) -> Bool

  /// - Parameter present: Puts the raw picker view on screen for the fallback
  ///   path, returning false if it cannot. The default attaches it to the
  ///   foreground key window and removes it again after
  ///   `fallbackVisibleSeconds`, so a host that never handles the fallback is
  ///   not left with a floating button forever.
  public init(present: ((UIView) -> Bool)? = nil) {
    self.present = present ?? SystemBroadcastPicker.presentInKeyWindow
  }

  public static let fallbackVisibleSeconds: TimeInterval = 60

  public var respondsToButtonPressed: Bool {
    view.responds(to: Self.buttonPressedSelector)
  }

  public func configure(preferredExtension: String?, showsMicrophoneButton: Bool) {
    view.preferredExtension = preferredExtension
    view.showsMicrophoneButton = showsMicrophoneButton
  }

  public func pressButton() {
    view.perform(Self.buttonPressedSelector, with: nil)
  }

  public func presentRawPicker() -> Bool {
    present(view)
  }

  private static func presentInKeyWindow(_ view: UIView) -> Bool {
    guard
      let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive })?
        .windows.first(where: \.isKeyWindow)
    else { return false }

    view.center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
    window.addSubview(view)
    DispatchQueue.main.asyncAfter(deadline: .now() + fallbackVisibleSeconds) {
      view.removeFromSuperview()
    }
    return true
  }
}
#endif
