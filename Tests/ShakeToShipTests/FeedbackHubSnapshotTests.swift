#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import XCTest
  @testable import ShakeToShip

  /// Deterministic production component renders complement the full-screen simulator evidence.
  /// No render server or navigation glass is required by this hostless package test.
  @MainActor
  final class FeedbackHubSnapshotTests: XCTestCase {
    func testCardActionScalesForAccessibilityAndKeepsMinimumTouchHeight() throws {
      func size(_ dynamicTypeSize: DynamicTypeSize) throws -> CGSize {
        let content = FeedbackCardAction(title: "Send the complete report") {}
          .frame(width: 140)
          .environment(\.dynamicTypeSize, dynamicTypeSize)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return try XCTUnwrap(renderer.uiImage).size
      }
      let regular = try size(.large)
      let accessible = try size(.accessibility2)
      XCTAssertGreaterThanOrEqual(regular.height, 44)
      XCTAssertGreaterThan(accessible.height, regular.height)
    }

    func testHubComponents() async throws {
      for name in [
        "idea-row", "idea-row-dark", "idea-row-large-type", "prompt", "prompt-dark",
        "idea-row-lockin", "prompt-lockin",
      ] {
        let (_, model, root) = try await HubSnapshotFixtures.scene("ideas")
        let view: AnyView
        if name.hasPrefix("idea-row") {
          view = AnyView(FeedbackIdeaRow(idea: model.ideas[0]).padding(24))
        } else {
          let prompt = FeedbackPrompt(
            id: "p", kind: "yes_no", question: "Would saved drafts help you?", impressionId: "i")
          view = AnyView(FeedbackPromptCard(model: model, prompt: prompt).padding(24))
        }
        let themed =
          name.hasSuffix("lockin")
          ? AnyView(
            view.feedbackTheme().shakeToShipTheme(LockInStyledHost<EmptyView>.theme(dark: false)))
          : view
        let content = themed.frame(width: 402).background(
          name.hasSuffix("dark") ? Color.black : Color.white
        )
        .environment(\.colorScheme, name.hasSuffix("dark") ? .dark : .light)
        .environment(\.dynamicTypeSize, name.hasSuffix("large-type") ? .accessibility2 : .large)
        .tint(.blue)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let png = try XCTUnwrap(image.pngData())
        let shared =
          ProcessInfo.processInfo.environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"]
          .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let output = shared.appendingPathComponent("sts-hub-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let baseline = Bundle.module.url(
          forResource: name, withExtension: "png", subdirectory: "Snapshots"),
          let expected = UIImage(contentsOfFile: baseline.path)
        {
          compare(image, expected: expected, name: name)
        } else {
          XCTFail("Missing baseline: \(name). Review the rendered image before adding it.")
        }
        await model.client.setActive(false)
        ShakeToShip.model = nil
        try? FileManager.default.removeItem(at: root)
      }
    }
    private func compare(_ actual: UIImage, expected: UIImage, name: String) {
      guard let a = pixels(actual), let b = pixels(expected), a.count == b.count else {
        XCTFail("Snapshot dimensions differ: \(name)")
        return
      }
      var different = 0
      for i in stride(from: 0, to: a.count, by: 4) {
        if (0..<3).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 8 }) { different += 1 }
      }
      XCTAssertLessThan(Double(different) / Double(a.count / 4), 0.005, "Snapshot differs: \(name)")
    }
    private func pixels(_ image: UIImage) -> [UInt8]? {
      guard let image = image.cgImage else { return nil }
      var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
      let ok = data.withUnsafeMutableBytes { bytes -> Bool in
        guard
          let context = CGContext(
            data: bytes.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
      }
      return ok ? data : nil
    }
  }
#endif
