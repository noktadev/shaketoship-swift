#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import XCTest
  @testable import ShakeToShip

  @MainActor
  final class FeedbackHubThemeTests: XCTestCase {
    func testDefaultThemePreservesHostTintAndFont() throws {
      let control = Button("Host action") {}.buttonStyle(.bordered)
      let original = control.tint(.orange).font(.system(.title, design: .monospaced))
      let themed = control.feedbackTheme().tint(.orange).font(.system(.title, design: .monospaced))
      XCTAssertEqual(try render(original), try render(themed))
      let override = control.feedbackTheme()
        .shakeToShipTheme(ShakeToShipTheme(accent: .purple))
        .tint(.orange).font(.system(.title, design: .monospaced))
      XCTAssertNotEqual(try render(original), try render(override))
    }

    func testIdeaTypographyInheritsExplicitHostFont() async throws {
      let (_, model, root) = try await HubSnapshotFixtures.scene("ideas")
      defer {
        try? FileManager.default.removeItem(at: root)
        ShakeToShip.model = nil
      }
      let row = FeedbackIdeaRow(idea: model.ideas[0])
      let original = row.font(.system(.title, design: .monospaced))
      let themed = row.feedbackTheme().font(.system(.title, design: .monospaced))
      XCTAssertEqual(try render(original), try render(themed))
      XCTAssertNotEqual(try render(row), try render(themed))
      await model.client.setActive(false)
    }

    func testComposerSurfaceOverrideDoesNotRequireRadius() async throws {
      let data = FeedbackComposerData(
        id: "theme-test", dir: FileManager.default.temporaryDirectory,
        events: [], capabilities: [.text], showsTrail: false)
      let composer = FeedbackComposer(
        data: data, onSend: { _ in }, onDiscard: {}, inheritsHostStyle: true)
      let original = try await renderHosted(composer, height: 350)
      let overridden = try await renderHosted(
        composer.shakeToShipTheme(ShakeToShipTheme(surface: .orange)), height: 350)
      XCTAssertNotEqual(original, overridden)
    }

    func testInputPrimaryTextOverrideOnContrastingSurface() async throws {
      let field = TextField("Title", text: .constant("A readable title"))
        .textFieldStyle(.plain).feedbackPrimaryText().padding().background(.black)
      let visible = try await renderHosted(
        field.shakeToShipTheme(ShakeToShipTheme(surface: .black, primaryText: .white)))
      let hidden = try await renderHosted(
        field.shakeToShipTheme(ShakeToShipTheme(surface: .black, primaryText: .black)))
      XCTAssertNotEqual(visible, hidden)
    }

    func testErrorSectionUsesContrastingHostSurface() async throws {
      let (_, model, root) = try await HubSnapshotFixtures.scene("ideas-error")
      defer {
        try? FileManager.default.removeItem(at: root)
        ShakeToShip.model = nil
      }
      let content = List { FeedbackHubErrorSection(model: model) }.listStyle(.insetGrouped)
      let dark = try await renderHosted(
        content.shakeToShipTheme(ShakeToShipTheme(surface: .black, primaryText: .white)),
        height: 350)
      let light = try await renderHosted(
        content.shakeToShipTheme(ShakeToShipTheme(surface: .white, primaryText: .white)),
        height: 350)
      XCTAssertNotEqual(dark, light)
      await model.client.setActive(false)
    }

    func testAttachedReportConfirmationUsesContrastingHostSurface() async throws {
      let (_, model, root) = try await HubSnapshotFixtures.scene("ideas")
      defer {
        try? FileManager.default.removeItem(at: root)
        ShakeToShip.model = nil
      }
      let content = Form {
        FeedbackExistingReportDetail(model: model, ideaID: "sample").confirmation
      }
      let dark = try await renderHosted(
        content.shakeToShipTheme(ShakeToShipTheme(surface: .black, primaryText: .white)),
        height: 350)
      let light = try await renderHosted(
        content.shakeToShipTheme(ShakeToShipTheme(surface: .white, primaryText: .white)),
        height: 350)
      XCTAssertNotEqual(dark, light)
      await model.client.setActive(false)
    }

    private func renderHosted<V: View>(_ view: V, height: CGFloat = 120) async throws -> Data {
      let host = UIHostingController(rootView: view.environment(\.colorScheme, .light))
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: height))
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      host.view.frame = window.bounds
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { context in
        host.view.layer.render(in: context.cgContext)
      }
      let attachment = XCTAttachment(image: image)
      attachment.lifetime = .keepAlways
      add(attachment)
      return try XCTUnwrap(image.pngData())
    }

    private func render<V: View>(_ view: V) throws -> Data {
      let renderer = ImageRenderer(
        content: view.padding().frame(width: 402).background(.white)
          .environment(\.colorScheme, .light).environment(\.dynamicTypeSize, .large))
      renderer.scale = 1
      return try XCTUnwrap(renderer.uiImage?.pngData())
    }
  }
#endif
