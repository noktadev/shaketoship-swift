import Foundation
import Testing
@testable import ShakeToShip

struct FeedbackReportScreenshotTests {
  @Test func screenshotIsFirstAttachmentAndCanBeRemovedBeforeSend() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let screenshot = Data("screenshot jpeg".utf8)
    let media = try FeedbackReportScreenshot.stage(screenshot, in: dir)
    #expect(media.count == 1)
    #expect(FeedbackComposerRules.showsRemove(for: media[0]))
    #expect(persistComposedReport(.init(media: media, note: "Bug"), in: dir))
    let first = dir.appendingPathComponent("attachment-0.jpg")
    #expect(try Data(contentsOf: first) == screenshot)
    #expect(persistComposedReport(.init(media: [], note: "No screenshot"), in: dir))
    #expect(!FileManager.default.fileExists(atPath: first.path))
  }

  @Test func excludedCaptureCreatesNoStagedAttachment() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(try FeedbackReportScreenshot.stage(nil, in: dir).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
  }

  @Test @MainActor func configCopyPreservesScreenshotExclusion() {
    let config = ShakeToShipConfig(app: "test", collectorURL: URL(string: "https://example.test")!,
      secret: "test", screenshotExclusion: { true })
    #expect(config.with(onFunnelEvent: nil, onOptOut: nil).screenshotExclusion())
  }
}
