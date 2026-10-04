import Foundation

/// Uses the same staged-image and attachment-0 contract as the photo picker.
enum FeedbackReportScreenshot {
  static func stage(_ jpeg: Data?, in directory: URL) throws -> [FeedbackMediaItem] {
    guard let jpeg else { return [] }
    let staging = directory.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let file = staging.appendingPathComponent("report-screenshot.jpg")
    try jpeg.write(to: file, options: .atomic)
    return [.picked(file, .image)]
  }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

/// Host capture-seal covers can opt into the same redaction during in-app capture.
/// The view behind the cover (for example a brand seal) remains in the screenshot.
@MainActor
public protocol ShakeToShipScreenshotConcealing: AnyObject {
  var screenshotConcealedView: UIView? { get }
}

extension FeedbackReportScreenshot {
  @MainActor static func capture(config: ShakeToShipConfig) -> Data? {
    guard config.capabilities.contains(.screenRecording), !config.screenshotExclusion(),
      let host = FeedbackSDKPresentationMarker.hostController(), host.isViewLoaded
    else { return nil }
    return render(host.view)
  }

  @MainActor static func captureForReport(model: FeedbackHubModel) -> Data? {
    guard model.active, model.config.capabilities.contains(.screenRecording),
      !model.config.screenshotExclusion() else { return nil }
    // UIKit can detach the presenter once a sheet covers it. Retain the clean
    // host capture taken immediately before entry presentation in that case.
    return capture(config: model.config) ?? model.reportScreenshot
  }

  @MainActor static func render(_ view: UIView) -> Data? {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
    var concealed: [(UIView, Bool)] = []
    func conceal(_ current: UIView) {
      if let cover = (current as? any ShakeToShipScreenshotConcealing)?.screenshotConcealedView {
        concealed.append((cover, cover.isHidden)); cover.isHidden = true
        return
      }
      if let field = current as? UITextField, field.isSecureTextEntry {
        concealed.append((field, field.isHidden)); field.isHidden = true
        return
      }
      current.subviews.forEach(conceal)
    }
    conceal(view)
    defer { for (cover, hidden) in concealed { cover.isHidden = hidden } }
    let format = UIGraphicsImageRendererFormat()
    format.scale = min(UIScreen.main.scale,
      FeedbackAttachmentBounds.maxImageDimension / max(view.bounds.width, view.bounds.height))
    var rendered = false
    let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
    var image = renderer.image { _ in
      rendered = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
    }
    if !rendered {
      // A covered presenter can be detached from the render server. Its local
      // layer tree still contains the host, with the same covers concealed.
      image = renderer.image { context in view.layer.render(in: context.cgContext) }
    }
    return image.jpegData(compressionQuality: FeedbackAttachmentBounds.jpegCompressionQuality)
  }
}

/// Preview and custom hosts register their own window without a scene search.
struct FeedbackHostWindowReader: UIViewRepresentable {
  final class WindowView: UIView {
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let window { ShakeToShip.hostWindow = window }
    }
  }
  func makeUIView(context: Context) -> WindowView { WindowView() }
  func updateUIView(_ view: WindowView, context: Context) {}
}

struct FeedbackReportPresentation: Identifiable {
  let id = UUID()
  let screenshot: Data?
}

/// Identifies SDK sheets without dismissing the host's Settings sheet or navigation.
struct FeedbackSDKPresentationMarker: UIViewControllerRepresentable {
  final class Controller: UIViewController {
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
  }
  func makeUIViewController(context: Context) -> Controller { Controller() }
  func updateUIViewController(_ controller: Controller, context: Context) {}

  @MainActor static func containsMarker(_ controller: UIViewController) -> Bool {
    controller is Controller || controller.children.contains(where: containsMarker)
  }
  @MainActor static func hostController(root: UIViewController? = nil) -> UIViewController? {
    guard var host = root ?? ShakeToShip.hostWindow?.rootViewController else { return nil }
    while let presented = host.presentedViewController, !containsMarker(presented) {
      host = presented
    }
    return host
  }
  @MainActor static func requestWalkthrough(root: UIViewController? = nil) {
    guard FeedbackManualTrigger.isRecordingAvailable,
      let host = hostController(root: root) else { return }
    FeedbackManualTrigger.prepareRecording()
    if let presented = host.presentedViewController, containsMarker(presented) {
      host.dismiss(animated: true) { FeedbackManualTrigger.signalRecording() }
    } else {
      FeedbackManualTrigger.signalRecording()
    }
  }
}

struct FeedbackRecordingDeviceHint: View {
  var body: some View {
    #if targetEnvironment(simulator)
    Text("Recording needs a real device.").font(.caption2).foregroundStyle(.tertiary)
      .accessibilityIdentifier("ShakeToShip.recordingDeviceHint")
    #endif
  }
}

struct FeedbackWalkthroughButton: View {
  var action: () -> Void = { FeedbackSDKPresentationMarker.requestWalkthrough() }
  var body: some View {
    if FeedbackManualTrigger.isRecordingAvailable {
    Button(action: action) {
      Label("Record a walkthrough", systemImage: "record.circle")
        .labelStyle(.titleAndIcon).lineLimit(1).frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent).controlSize(.regular)
    .dynamicTypeSize(...DynamicTypeSize.large).frame(maxHeight: 44)
    .accessibilityIdentifier("ShakeToShip.recordWalkthrough")
    }
  }
}
#endif
