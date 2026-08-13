#if canImport(UIKit)
import SwiftUI
import UIKit

#if !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)

/// Presents `FeedbackReviewSheet` in a dedicated overlay UIWindow so it can
/// never collide with a host app's own fullScreenCover/sheet presentations
/// (#406: dotself's root already owns covers + sheets, which suppressed the
/// modifier's `fullScreenCover`). The window is deliberately NOT made key:
/// shake detection rides the host key window's responder chain.
@MainActor
final class FeedbackReviewWindowPresenter {
  private var window: UIWindow?
  // Held so `dismiss()` can unregister them. NOT touched from `deinit`: a
  // nonisolated deinit cannot access this MainActor-isolated property under
  // Swift 6 strict concurrency. Cleanup happens in `dismiss()`, which the
  // decision handlers AND the scene-teardown observers below all call; the
  // observers capture `[weak self]`, so a presenter released without a dismiss
  // leaves only inert no-op registrations (harmless in this DEBUG-only tool).
  private var teardownObservers: [NSObjectProtocol] = []

  var isPresenting: Bool { window != nil }

  /// Returns false when no UIWindowScene is available (backgrounded stop);
  /// the caller leaves the session unconfirmed in the outbox, mirroring the
  /// interruption path.
  func present(
    data: FeedbackReviewData,
    onUpload: @escaping () -> Void,
    onDiscard: @escaping () -> Void,
    onOptOut: (@MainActor @Sendable () -> Void)? = nil
  ) -> Bool {
    guard window == nil else { return false }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
      ?? scenes.first
    else { return false }

    let window = UIWindow(windowScene: scene)
    window.windowLevel = .alert + 1
    // Dismiss BEFORE invoking the decision handler so a slow upload never
    // holds the window on screen (same ordering as the old cover's
    // `reviewSession = nil` first line).
    window.rootViewController = UIHostingController(
      rootView: FeedbackReviewSheet(
        data: data,
        onUpload: { [weak self] in
          self?.dismiss()
          onUpload()
        },
        onDiscard: { [weak self] in
          self?.dismiss()
          onDiscard()
        },
        onOptOut: onOptOut.map { optOut in
          { [weak self] in
            self?.dismiss()
            optOut()
          }
        }))
    window.isHidden = false  // NOT makeKeyAndVisible() - see type comment.
    self.window = window

    // The decision handlers transitively retain the SwiftUI modifier that owns
    // this presenter, so if the scene disconnects or the app is killed BEFORE
    // Upload/Discard is tapped, nothing dismisses the window and the overlay
    // leaks (the session stays finalized+unconfirmed in the outbox, correct).
    // Tear the window down on those terminal scene events to break the cycle.
    let center = NotificationCenter.default
    for name in [UIScene.didDisconnectNotification, UIApplication.didEnterBackgroundNotification] {
      teardownObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.dismiss() }
        })
    }
    return true
  }

  func dismiss() {
    for observer in teardownObservers { NotificationCenter.default.removeObserver(observer) }
    teardownObservers.removeAll()
    window?.isHidden = true
    window = nil
  }
}

#endif  // DEBUG && !simulator && !catalyst
#endif  // canImport(UIKit)
