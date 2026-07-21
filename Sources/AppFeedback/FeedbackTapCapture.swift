import Foundation

#if canImport(UIKit)
import UIKit

/// Window-level tap capture, installed ONLY while recording.
///
/// NOT unit tested - a real UIWindow + responder chain. Kept deliberately thin:
/// every decision it makes (coordinate normalization, which accessibility
/// string wins, truncation) lives in `FeedbackTapFormatting`, which is.
///
/// The recognizer never consumes touches (`cancelsTouchesInView = false`,
/// `delaysTouchesBegan/Ended = false`) and its delegate recognises
/// simultaneously with everything, so normal app interaction, sheets, and
/// scroll views behave exactly as before.
@MainActor
enum FeedbackTapCapture {
  private static var recognizer: FeedbackTapRecognizer?

  /// Attaches to the current key window. Idempotent.
  static func install() {
    guard recognizer == nil, let window = keyWindow() else { return }
    let gesture = FeedbackTapRecognizer()
    window.addGestureRecognizer(gesture)
    recognizer = gesture
  }

  /// Detaches from whatever window it was attached to. Idempotent.
  static func remove() {
    guard let recognizer else { return }
    recognizer.view?.removeGestureRecognizer(recognizer)
    self.recognizer = nil
  }

  private static func keyWindow() -> UIWindow? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
  }
}

/// Reports every touch-down into the trail without affecting delivery.
///
/// Uses raw `touchesBegan` (rather than a `UITapGestureRecognizer`) so a tap is
/// recorded even when it turns into a scroll or a long press: the trail wants
/// where the user reached, not only gestures that resolve to a clean tap. The
/// recognizer stays `.failed`, so it never enters the recognized state and can
/// never swallow a touch.
@MainActor
private final class FeedbackTapRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
    delegate = self
  }

  convenience init() {
    self.init(target: nil, action: nil)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    if let touch = touches.first, let window = view as? UIWindow {
      record(touch, in: window)
    }
    state = .failed
  }

  private func record(_ touch: UITouch, in window: UIWindow) {
    let point = touch.location(in: window)
    let bounds = window.bounds
    let element = FeedbackTapCapture.elementDescription(at: point, in: window)
    // Hoisted locals only: nothing captured beyond value types (86f71c7b).
    Feedback.tap(
      x: FeedbackTapFormatting.normalized(point.x, in: bounds.width),
      y: FeedbackTapFormatting.normalized(point.y, in: bounds.height),
      element: element)
  }

  nonisolated func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool { true }
}

extension FeedbackTapCapture {
  /// Bounds on the recursive walk below so a deep or cyclic hierarchy can
  /// never spin the main thread - this runs on every touch-down.
  private static let maxWalkDepth = 25
  private static let maxWalkVisits = 2000

  /// Resolves the name of whatever the user tapped.
  ///
  /// SwiftUI vends `.accessibilityLabel`/`.accessibilityIdentifier` as
  /// `UIAccessibilityElement`s from `_UIHostingView`, not as UIView
  /// properties - a plain `window.hitTest` walk returns hosting/drawing
  /// views with nothing set on them, so a pure-SwiftUI screen resolves to
  /// nil almost everywhere. This tries the accessibility tree FIRST
  /// (`accessibilityElements` where a container vends them, `subviews`
  /// otherwise), then falls back to the previous UIView hit-test walk for
  /// hierarchies that expose no accessibility tree at all.
  ///
  /// `accessibilityFrame` is reported in SCREEN coordinates by UIKit
  /// (regardless of whether the node is a UIView or a UIAccessibilityElement);
  /// the incoming `point` is in window coordinates, so it is converted with
  /// `window.convert(_:to:)` before any frame comparison. Getting this wrong
  /// would silently resolve the wrong element (or none) on every tap.
  ///
  /// Returns nil when nothing resolvable was found - the caller keeps the
  /// coordinates.
  static func elementDescription(at point: CGPoint, in window: UIWindow) -> String? {
    let screenPoint = window.convert(point, to: nil)
    var hits: [FeedbackTapFormatting.AccessibilityHit] = []
    var visited = 0
    collectAccessibilityHits(
      from: window, depth: 0, screenPoint: screenPoint, visited: &visited, into: &hits)
    if let name = FeedbackTapFormatting.deepestNamedHit(hits) {
      return name
    }
    return uiViewHitTestDescription(at: point, in: window)
  }

  /// Depth-first walk of the accessibility tree from `node`, recording every
  /// descendant whose on-screen frame contains `screenPoint` together with
  /// its depth. Which of the collected hits actually wins is pure logic,
  /// tested separately as `FeedbackTapFormatting.deepestNamedHit`.
  private static func collectAccessibilityHits(
    from node: NSObject,
    depth: Int,
    screenPoint: CGPoint,
    visited: inout Int,
    into hits: inout [FeedbackTapFormatting.AccessibilityHit]
  ) {
    guard depth <= maxWalkDepth, visited <= maxWalkVisits else { return }
    visited += 1

    hits.append(FeedbackTapFormatting.AccessibilityHit(depth: depth, name: name(of: node)))

    for child in accessibilityChildren(of: node) {
      // Bound the walk by nodes INSPECTED, not nodes recursed into: this loop
      // reads accessibilityFrame on every child, so a flat 5000-row list under
      // one container would otherwise scan unbounded on the touch-down path
      // (main thread, mid-gesture).
      visited += 1
      guard visited <= maxWalkVisits else { return }
      guard !isHiddenFromAccessibility(child) else { continue }
      guard child.accessibilityFrame.contains(screenPoint) else { continue }
      collectAccessibilityHits(
        from: child, depth: depth + 1, screenPoint: screenPoint, visited: &visited, into: &hits)
    }
  }

  /// A node's children for the purposes of this walk: whatever it vends via
  /// `accessibilityElements` (SwiftUI hosting views, custom containers), or
  /// its `subviews` when it vends none. When a child declares itself
  /// `accessibilityViewIsModal`, its siblings are excluded, matching how
  /// VoiceOver itself treats a modal presentation.
  private static func accessibilityChildren(of node: NSObject) -> [NSObject] {
    let children: [NSObject]
    if let elements = node.accessibilityElements, !elements.isEmpty {
      children = elements.compactMap { $0 as? NSObject }
    } else if let view = node as? UIView {
      children = view.subviews
    } else {
      children = []
    }
    let modalOnly = children.filter { ($0 as? UIView)?.accessibilityViewIsModal == true }
    return modalOnly.isEmpty ? children : modalOnly
  }

  /// Cheap hidden checks only - `accessibilityElementsHidden` applies to any
  /// node, `isHidden` only to views (accessibility elements have no view of
  /// their own to hide).
  private static func isHiddenFromAccessibility(_ node: NSObject) -> Bool {
    if node.accessibilityElementsHidden { return true }
    if let view = node as? UIView, view.isHidden { return true }
    return false
  }

  /// `accessibilityLabel`/`accessibilityFrame`/`accessibilityElementsHidden`
  /// are NSObject-level (any accessibility node has them); `accessibilityIdentifier`
  /// lives on the concrete `UIAccessibilityIdentification` adopters, probed by
  /// CLASS cast below - never by protocol cast.
  private static func name(of node: NSObject) -> String? {
    FeedbackTapFormatting.elementText(
      label: node.accessibilityLabel,
      identifier: accessibilityIdentifier(of: node),
      title: (node as? UIButton)?.titleLabel?.text
        ?? (node as? UILabel)?.text)
  }

  /// On iOS 27, `node as? UIAccessibilityIdentification` traps in the Swift
  /// runtime (`swift_dynamicCastObjCProtocolUnconditional` -> SIGABRT) when
  /// `node` is one of SwiftUI's private hosting views
  /// (`_UIHostingView<TabItem.RootView>`, lockin-chinese 1.0+81 crash on the
  /// first touch of every recording) instead of failing the conditional cast.
  /// Class casts never enter the ObjC-protocol cast path, so probe the
  /// concrete adopters directly.
  private static func accessibilityIdentifier(of node: NSObject) -> String? {
    if let view = node as? UIView { return view.accessibilityIdentifier }
    if let element = node as? UIAccessibilityElement { return element.accessibilityIdentifier }
    if let barItem = node as? UIBarItem { return barItem.accessibilityIdentifier }
    return nil
  }

  /// Prior behavior, kept as the fallback for hierarchies with no
  /// accessibility tree: hit-tests `point` and walks from the deepest hit
  /// UIView UP to the nearest ancestor exposing something nameable.
  private static func uiViewHitTestDescription(at point: CGPoint, in window: UIWindow) -> String? {
    var view = window.hitTest(point, with: nil)
    while let current = view {
      if let text = name(of: current) {
        return text
      }
      view = current.superview
    }
    return nil
  }
}
#endif  // canImport(UIKit)
