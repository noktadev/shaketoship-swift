#if canImport(UIKit)
  import SwiftUI
  import Testing
  @testable import ShakeToShip

  @MainActor
  struct FeedbackHubBannerTests {
    @Test func publicBannerTracksBothRuntimeGates() async throws {
      let transport = HubTestTransport()
      let (client, root, _) = try FeedbackHubClientTests().fixture(
        transport: transport, hub: [.prompts])
      defer {
        try? FileManager.default.removeItem(at: root)
        ShakeToShip.model = nil
      }
      let model = FeedbackHubModel(client: client, config: await client.config)
      model.prompt = FeedbackPrompt(
        id: "prompt", kind: "yes_no", question: "Would drafts help?", impressionId: "served")
      ShakeToShip.model = model
      let visible = ImageRenderer(content: ShakeToShip.promptBanner().frame(width: 402)).uiImage
      #expect((visible?.size.height ?? 0) > 40)
      ShakeToShip.deactivate()
      model.prompt = FeedbackPrompt(
        id: "inactive", kind: "yes_no", question: "Still present", impressionId: "served")
      let inactive = ImageRenderer(content: ShakeToShip.promptBanner().frame(width: 402)).uiImage
      #expect((inactive?.size.height ?? 0) == 0)
      let (noPrompts, otherRoot, _) = try FeedbackHubClientTests().fixture(
        transport: transport, hub: [.ideas])
      defer { try? FileManager.default.removeItem(at: otherRoot) }
      let other = FeedbackHubModel(client: noPrompts, config: await noPrompts.config)
      other.prompt = FeedbackPrompt(
        id: "nonempty", kind: "yes_no", question: "Still present", impressionId: "served")
      ShakeToShip.model = other
      let disabled = ImageRenderer(content: ShakeToShip.promptBanner().frame(width: 402)).uiImage
      #expect((disabled?.size.height ?? 0) == 0)
      #expect(await transport.requests.isEmpty)
    }
  }
#endif
