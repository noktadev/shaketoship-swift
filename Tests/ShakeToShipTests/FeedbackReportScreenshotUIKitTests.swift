#if canImport(UIKit)
import UIKit
import XCTest
@testable import ShakeToShip

@MainActor
final class FeedbackReportScreenshotUIKitTests: XCTestCase {
  final class SealProbe: UIView, ShakeToShipScreenshotConcealing {
    let cover = UIView()
    var screenshotConcealedView: UIView? { cover }
    var concealedDuringCapture = false
    override func drawHierarchy(in rect: CGRect, afterScreenUpdates: Bool) -> Bool {
      concealedDuringCapture = cover.isHidden
      // The package test runner has no live window scene. Draw a deterministic
      // probe while observing the same conceal/restore interval as UIKit.
      (cover.isHidden ? UIColor.red : UIColor.blue).setFill()
      UIRectFill(rect)
      return true
    }
  }

  func testCaptureConcealsSealCoverAndRestoresLiveView() async throws {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let host = UIViewController()
    let probe = SealProbe(frame: window.bounds)
    probe.backgroundColor = .red
    probe.cover.frame = probe.bounds
    probe.cover.backgroundColor = .blue
    probe.addSubview(probe.cover)
    host.view = probe
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    probe.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNotNil(FeedbackReportScreenshot.render(probe))
    XCTAssertTrue(probe.concealedDuringCapture)
    XCTAssertFalse(probe.cover.isHidden)
    let config = ShakeToShipConfig(app: "test", collectorURL: URL(string: "https://example.test")!,
      secret: "test", capabilities: .all, screenshotExclusion: { true })
    XCTAssertNil(FeedbackReportScreenshot.capture(config: config))
  }

  func testDismissalClearsCachedScreenshotBeforeFailedCapture() async throws {
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: HubTestTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    let model = FeedbackHubModel(client: client, config: await client.config)
    model.reportScreenshot = Data("previous session".utf8)
    model.endReportPresentation()
    let previousWindow = ShakeToShip.hostWindow
    ShakeToShip.hostWindow = nil
    defer { ShakeToShip.hostWindow = previousWindow }
    XCTAssertNil(FeedbackReportScreenshot.captureForReport(model: model))
  }

  func testCaptureAndDismissalUseRegisteredHostWindow() {
    let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let second = UIWindow(frame: first.bounds)
    let firstRoot = PresentationProbe()
    let secondRoot = PresentationProbe()
    let firstView = SealProbe(frame: first.bounds)
    let secondView = SealProbe(frame: second.bounds)
    firstRoot.view = firstView; secondRoot.view = secondView
    first.rootViewController = firstRoot; second.rootViewController = secondRoot
    let sdk = UIViewController()
    let marker = FeedbackSDKPresentationMarker.Controller()
    sdk.addChild(marker); sdk.view.addSubview(marker.view)
    secondRoot.presented = sdk
    let unrelated = UIViewController()
    firstRoot.presented = unrelated
    let previousWindow = ShakeToShip.hostWindow
    ShakeToShip.hostWindow = second
    defer { ShakeToShip.hostWindow = previousWindow; FeedbackManualTrigger.unregister() }
    let config = ShakeToShipConfig(app: "test", collectorURL: URL(string: "https://example.test")!,
      secret: "test", capabilities: .all)
    XCTAssertNotNil(FeedbackReportScreenshot.capture(config: config))
    XCTAssertTrue(secondView.concealedDuringCapture)
    XCTAssertFalse(firstView.concealedDuringCapture)
    var routed = false
    FeedbackManualTrigger.register({}, recording: { routed = true })
    FeedbackSDKPresentationMarker.requestWalkthrough()
    XCTAssertTrue(routed)
    XCTAssertNil(secondRoot.presented)
    XCTAssertTrue(firstRoot.presented === unrelated)
  }

  final class PresentationProbe: UIViewController {
    var presented: UIViewController?
    override var presentedViewController: UIViewController? { presented }
    override func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
      presented = nil
      completion?()
    }
  }

  func testWalkthroughDismissesSDKSheetsAndPreservesHostSettings() {
    let root = PresentationProbe()
    let settings = PresentationProbe()
    let sdk = UIViewController()
    let marker = FeedbackSDKPresentationMarker.Controller()
    sdk.addChild(marker); sdk.view.addSubview(marker.view); marker.didMove(toParent: sdk)
    root.presented = settings
    settings.presented = sdk
    XCTAssertTrue(FeedbackSDKPresentationMarker.hostController(root: root) === settings)
    var prepared = false
    var routed = false
    defer { FeedbackManualTrigger.unregister() }
    FeedbackManualTrigger.register({ XCTFail("Must request recording consent, not the hub") },
      recording: {
        XCTAssertTrue(prepared)
        XCTAssertNil(settings.presentedViewController)
        XCTAssertTrue(root.presentedViewController === settings)
        routed = true
      }, prepareRecording: { prepared = true })
    FeedbackSDKPresentationMarker.requestWalkthrough(root: root)
    XCTAssertTrue(routed)
  }
}
#endif
