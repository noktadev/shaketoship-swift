#if canImport(UIKit)
  import SwiftUI
  import UIKit

  /// The annotation trail the cursor's nib leaves behind.
  ///
  /// Explicitly inert (`allowsHitTesting(false)`): the ink must never take a
  /// touch from the host app, which is the failure the bar it replaces actually
  /// shipped (#1183).
  ///
  /// Weight is the lab's `faint` setting. The first pass was a 4.5pt core at
  /// 0.95 alpha with a 16pt glow and it dominated the screen, competing with the
  /// very thing it was meant to point at.
  struct FeedbackInkTrail: View {
    let strokes: [[FeedbackInkPoint]]
    let dismissedAt: TimeInterval?

    private let coreWidth: CGFloat = 2.2
    private let coreAlpha: Double = 0.38
    private let glowWidth: CGFloat = 8
    private let glowAlpha: Double = 0.07

    var body: some View {
      TimelineView(.animation) { timeline in
        Canvas { context, _ in
          let now = timeline.date.timeIntervalSinceReferenceDate
          let dismiss = FeedbackInkFade.dismissFactor(now: now, dismissedAt: dismissedAt)
          guard dismiss > 0 else { return }

          for stroke in strokes where stroke.count > 1 {
            for index in 1..<stroke.count {
              let age = now - stroke[index].t
              guard age <= FeedbackInkFade.lifetime else { continue }
              let life = FeedbackInkFade.life(age: age) * dismiss
              guard life > 0 else { continue }

              var segment = Path()
              segment.move(to: CGPoint(x: stroke[index - 1].x, y: stroke[index - 1].y))
              segment.addLine(to: CGPoint(x: stroke[index].x, y: stroke[index].y))

              // Wide soft pass first, then a crisp core: the glow is what makes
              // it read as ink rather than a hairline scratch.
              context.stroke(
                segment, with: .color(.red.opacity(life * glowAlpha)),
                style: StrokeStyle(
                  lineWidth: glowWidth * life + 3, lineCap: .round, lineJoin: .round))
              context.stroke(
                segment, with: .color(.red.opacity(life * coreAlpha)),
                style: StrokeStyle(
                  lineWidth: coreWidth * life + 1, lineCap: .round, lineJoin: .round))
            }
          }
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  /// Reports window touch-downs without consuming them.
  ///
  /// `cancelsTouchesInView = false` plus a delegate that declines every touch
  /// means the host app keeps all of them. This is the same discipline
  /// `FeedbackTapCapture` already uses to log the tap trail, so retiring the ink
  /// on a background tap adds no new interception - and therefore cannot
  /// reintroduce the blocking bug.
  struct FeedbackWindowTouchObserver: UIViewRepresentable {
    let onTouch: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTouch: onTouch) }

    func makeUIView(context: Context) -> UIView {
      let view = UIView()
      view.isUserInteractionEnabled = false
      let coordinator = context.coordinator
      DispatchQueue.main.async {
        guard let window = view.window, coordinator.recognizer == nil else { return }
        let recognizer = UIGestureRecognizer(
          target: coordinator, action: #selector(Coordinator.noop))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = coordinator
        window.addGestureRecognizer(recognizer)
        coordinator.window = window
        coordinator.recognizer = recognizer
      }
      return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
      context.coordinator.onTouch = onTouch
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
      if let recognizer = coordinator.recognizer {
        coordinator.window?.removeGestureRecognizer(recognizer)
      }
      coordinator.recognizer = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      var onTouch: (CGPoint) -> Void
      weak var window: UIWindow?
      var recognizer: UIGestureRecognizer?

      init(onTouch: @escaping (CGPoint) -> Void) { self.onTouch = onTouch }

      @objc func noop() {}

      func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
      ) -> Bool { true }

      func gestureRecognizer(
        _ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch
      ) -> Bool {
        if let window { onTouch(touch.location(in: window)) }
        return false  // observe, never take
      }
    }
  }
#endif
