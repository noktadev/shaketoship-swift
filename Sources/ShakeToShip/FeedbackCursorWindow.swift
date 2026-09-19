import CoreGraphics
import Foundation

/// Which touches the cursor's overlay window claims.
///
/// #1391: the pill moved out of the host's root `.overlay` into a window of its
/// own, because a root overlay renders BELOW every modal presentation - A Life
/// Story's call screen is a `fullScreenCover`, so the pill and its stop control
/// were unreachable for the whole call. A full-screen window at a high level
/// fixes the visibility, and this rule is what stops it from also swallowing the
/// app: the window claims the pill's own hit box and NOTHING else. Fails closed -
/// an unknown frame claims nothing - because the failure mode in the other
/// direction is an app that cannot be touched at all (#1183).
///
/// Pure geometry, outside the UIKit gate, so the macOS package gate can pin it.
enum FeedbackPassThroughHit {
  /// True only when `point` (window coordinates) lands on the pill itself.
  static func claims(point: CGPoint, interactive: CGRect?) -> Bool {
    guard let interactive, !interactive.isEmpty else { return false }
    return interactive.contains(point)
  }
}

#if canImport(UIKit)
  import SwiftUI
  import UIKit

  #if !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)

    /// A window that is transparent to every touch except the pill's own.
    ///
    /// `interactiveFrame` is published by the pill as it is dragged and as it
    /// expands, so the claimed region always matches what is actually on screen.
    /// Comparing the hit view against the hosting view instead would not work:
    /// SwiftUI draws the whole pill inside one `_UIHostingView`, so every hit
    /// resolves to the same view whether or not the pill is under the finger.
    final class FeedbackPassThroughWindow: UIWindow {
      /// The pill's hit box in window coordinates; nil until it reports one.
      var interactiveFrame: CGRect?

      override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard FeedbackPassThroughHit.claims(point: point, interactive: interactiveFrame) else {
          return nil
        }
        return super.hitTest(point, with: event)
      }
    }

    /// Puts the recording cursor on screen as two pieces, in two places, for two
    /// different reasons.
    ///
    /// **The pill goes in a window of its own.** It has to be touchable above the
    /// host's own presentations, and only a higher window can do that: UIKit
    /// hit-tests windows by level and views by subview order, so a view inside
    /// the host window can be lifted visually but never made touchable above a
    /// `fullScreenCover`. Same remedy the review composer already needed on
    /// dotself (#406). The window is deliberately NOT made key, which buys three
    /// things at once: shake detection keeps working (it rides the host key
    /// window's responder chain), `FeedbackTapCapture` still attaches to the host
    /// window, and the status bar keeps taking its style from the host's root
    /// view controller rather than from this overlay.
    ///
    /// **The ink stays inside the host window.** A stroke is never serialized -
    /// `FeedbackInkPoint` is not `Codable` and the uploader sends only
    /// `events.json`, the MOV and the composer's attachments - so the captured
    /// video is the ONLY way an annotation reaches a reviewer. In-app ReplayKit
    /// capture is reported to see just the app's own window, so the ink layer is
    /// a subview of the host window, lifted over the host's presentations with
    /// `zPosition`. That changes what is composited without changing what is
    /// hit-tested, which is exactly right for a layer that must never take a
    /// touch, and it keeps the ink inside whatever ReplayKit records.
    @MainActor
    final class FeedbackCursorWindowPresenter {
      /// The host's own window, reported by the shake detector that lives in the
      /// host's view hierarchy. It picks the scene for the pill's window and it
      /// hosts the ink, so neither has to guess from `connectedScenes`. Weak: the
      /// scene owns this window, and an SDK must never be the reason it outlives
      /// its scene.
      private(set) weak var hostWindow: UIWindow?
      private let ink = FeedbackInkCanvas()
      private var window: FeedbackPassThroughWindow?
      private var host: UIHostingController<FeedbackRecordingCursor>?
      private var inkHost: UIHostingController<FeedbackInkLayer>?
      /// The scene whose teardown takes this presenter's window with it, and the
      /// observer watching it. Cleanup happens here rather than in `deinit`: a
      /// nonisolated deinit cannot touch MainActor state under Swift 6.
      private var ownerScene: UIWindowScene?
      private var teardownObserver: NSObjectProtocol?

      var isPresenting: Bool { window != nil }

      /// Records the host's window. Called whenever the shake detector moves to a
      /// window, so a scene change is picked up before the next recording.
      func setHostWindow(_ window: UIWindow?) {
        hostWindow = window
      }

      /// Shows the cursor, or updates the one already on screen. Returns false
      /// when no window scene is available (a backgrounded start), in which case
      /// the caller simply tries again on the next state change.
      @discardableResult
      func show(
        microphoneAllowed: Bool,
        paused: Bool,
        startedAt: Date,
        stopHintVisible: Bool,
        onStop: @escaping () -> Void,
        onTogglePause: @escaping () -> Void
      ) -> Bool {
        ink.stopHintVisible = stopHintVisible
        let window: FeedbackPassThroughWindow
        if let existing = self.window {
          window = existing
        } else {
          // The scene the recording was started FROM. Falling back to a
          // foreground-active scene only matters if the detector never reached a
          // window, which is also the only case where there is nothing better to
          // pick.
          let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          guard
            let scene = hostWindow?.windowScene
              ?? scenes.first(where: { $0.activationState == .foregroundActive })
              ?? scenes.first
          else { return false }
          window = FeedbackPassThroughWindow(windowScene: scene)
          // Above the host's covers and sheets (they live in the normal window),
          // and below the review composer's `.alert + 1` so the composer still
          // covers the pill if the two ever overlap.
          window.windowLevel = .alert
          window.backgroundColor = .clear
          window.isOpaque = false
          ownerScene = scene
        }

        let cursor = FeedbackRecordingCursor(
          microphoneAllowed: microphoneAllowed,
          paused: paused,
          startedAt: startedAt,
          onStop: onStop,
          onTogglePause: onTogglePause,
          ink: ink,
          onInteractiveFrame: { [weak window] frame in window?.interactiveFrame = frame })

        showInkLayer()

        if let host {
          // Same view type in the same position, so SwiftUI keeps the pill's own
          // state: a session that pauses and resumes does not throw away where
          // the user parked the pill.
          host.rootView = cursor
          return true
        }

        let host = UIHostingController(rootView: cursor)
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        window.rootViewController = host
        // Shown, never made key: see the type comment. A guard test reads this
        // file for the absence of the key-window call, so do not name it here.
        window.isHidden = false
        self.host = host
        self.window = window
        observeSceneTeardown()
        return true
      }

      /// Adds the ink layer to the host window, or lifts the existing one back on
      /// top. `zPosition` is re-applied rather than assumed: a host that adds its
      /// own high-`zPosition` view mid-recording would otherwise bury the ink.
      private func showInkLayer() {
        // The detector's window is the honest answer; the key window is the only
        // fallback worth having, for a host whose detector has not reached a
        // window yet.
        guard let hostWindow = hostWindow ?? FeedbackTapCapture.keyWindow() else { return }
        if let inkHost, inkHost.view.superview === hostWindow {
          hostWindow.bringSubviewToFront(inkHost.view)
          inkHost.view.layer.zPosition = .greatestFiniteMagnitude
          inkHost.rootView = FeedbackInkLayer(
            ink: ink, hintTopInset: hostWindow.safeAreaInsets.top)
          return
        }
        inkHost?.view.removeFromSuperview()
        let controller = UIHostingController(
          rootView: FeedbackInkLayer(ink: ink, hintTopInset: hostWindow.safeAreaInsets.top))
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        // The layer covers the whole screen, so taking a touch here would block
        // the app completely. It never takes one.
        controller.view.isUserInteractionEnabled = false
        controller.view.frame = hostWindow.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.layer.zPosition = .greatestFiniteMagnitude
        hostWindow.addSubview(controller.view)
        inkHost = controller
      }

      /// The stop/pause handlers transitively retain the modifier that owns this
      /// presenter, so a scene disconnecting before a stop would leak the window.
      /// Scoped to the owning scene, twice: `object:` filters the registration,
      /// and the identity check survives a platform that ignores it. An unrelated
      /// scene closing must not take the stop control off a live recording.
      private func observeSceneTeardown() {
        guard teardownObserver == nil, let scene = ownerScene else { return }
        teardownObserver = NotificationCenter.default.addObserver(
          forName: UIScene.didDisconnectNotification, object: scene, queue: .main
        ) { [weak self] notification in
          // Reduced to an identity out here: a `Notification` is task-isolated
          // under Swift 6, so it cannot cross into the MainActor closure.
          let notified = notification.object.map { ObjectIdentifier($0 as AnyObject) }
          MainActor.assumeIsolated {
            guard let self, let owner = self.ownerScene else { return }
            guard
              FeedbackSceneTeardown.dismisses(
                notified: notified, owner: ObjectIdentifier(owner))
            else { return }
            self.dismiss()
          }
        }
      }

      func dismiss() {
        if let teardownObserver { NotificationCenter.default.removeObserver(teardownObserver) }
        teardownObserver = nil
        ownerScene = nil
        inkHost?.view.removeFromSuperview()
        inkHost = nil
        ink.clear()
        window?.isHidden = true
        window = nil
        host = nil
      }
    }

  #endif  // !simulator && !macCatalyst
#endif  // canImport(UIKit)
