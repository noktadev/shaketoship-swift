#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import XCTest
  @testable import ShakeToShip

  @MainActor
  final class FeedbackHubNavigationTests: XCTestCase {
    func testHubEntryListDoesNotReserveHiddenIdeasPrompt() async throws {
      let transport = HubTestTransport()
      await transport.prepare([(201, hubIdentityJSON()), (204, "")])
      let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
      defer { try? FileManager.default.removeItem(at: root) }
      await client.setActive(true)
      _ = try await client.identity()
      let model = FeedbackHubModel(client: client, config: await client.config)
      let host = UIHostingController(rootView: FeedbackHubView(model: model))
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      let requests = await transport.requests
      XCTAssertEqual(requests.map { $0.url!.path }, ["/identity"])
      XCTAssertNil(model.prompt)
      await client.setActive(false)
    }

    func testClosedPopoverDoesNotReservePrompt() async throws {
      let transport = HubTestTransport()
      await transport.prepare([(201, hubIdentityJSON())])
      let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
      defer {
        try? FileManager.default.removeItem(at: root)
        ShakeToShip.model = nil
      }
      await client.setActive(true)
      _ = try await client.identity()
      ShakeToShip.model = FeedbackHubModel(client: client, config: await client.config)
      let host = UIHostingController(
        rootView:
          ShakeToShipPromptPopover(isPresented: .constant(false)) { Text("Question") })
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      let paths = await transport.requests.map { $0.url!.path }
      XCTAssertEqual(paths, ["/identity"])
      await client.setActive(false)
    }

    func testLaterDetailSelectionRejectsEarlierResponse() async throws {
      let transport = HubTestTransport()
      await transport.prepare([(201, hubIdentityJSON())])
      let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
      defer { try? FileManager.default.removeItem(at: root) }
      await client.setActive(true)
      _ = try await client.identity()
      let model = FeedbackHubModel(client: client, config: await client.config)
      await transport.prepare([(200, HubSnapshotFixtures.ideaJSON)], suspend: true)
      let first = Task { await model.detail("sample") }
      for _ in 0..<100 {
        if await transport.requests.count == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      await transport.prepare([
        (200, HubSnapshotFixtures.ideaJSON.replacingOccurrences(of: "sample", with: "second"))
      ])
      await model.detail("second")
      XCTAssertEqual(model.selectedIdea?.id, "second")
      await transport.resume()
      await first.value
      XCTAssertEqual(model.selectedIdea?.id, "second")
      XCTAssertFalse(model.detailLoading)
      await client.setActive(false)
    }

    func testMountedIdeasReloadAfterIdentityReplacement() async throws {
      let transport = HubTestTransport()
      await transport.prepare([(201, hubIdentityJSON())])
      let (client, root, _) = try FeedbackHubClientTests().fixture(
        transport: transport, hub: [.ideas])
      defer {
        try? FileManager.default.removeItem(at: root)
        ShakeToShip.model = nil
      }
      await client.setActive(true)
      _ = try await client.identity()
      let model = FeedbackHubModel(client: client, config: await client.config)
      model.ideas = [
        try JSONDecoder().decode(FeedbackIdea.self, from: Data(HubSnapshotFixtures.ideaJSON.utf8))
      ]
      ShakeToShip.model = model
      await model.connect()
      let host = UIHostingController(rootView: ShakeToShipIdeasList())
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      await transport.prepare([
        (201, hubIdentityJSON("replacement")), (200, HubSnapshotFixtures.ideasJSON),
      ])
      try await client.reset()
      for _ in 0..<100 {
        if ShakeToShip.model?.ideas.count == 3 { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertFalse(ShakeToShip.model === model)
      XCTAssertEqual(ShakeToShip.model?.ideas.count, 3)
      await client.setActive(false)
    }

    func testMountedIdeasReservesAndDisplaysPrompt() async throws {
      try await exercisePromptSurfaces(ideas: true, banner: false)
    }
    func testMountedBannerReservesAndDisplaysPrompt() async throws {
      try await exercisePromptSurfaces(ideas: false, banner: true)
    }
    func testConcurrentSurfacesShareOneReservation() async throws {
      try await exercisePromptSurfaces(ideas: true, banner: true)
    }
    private func exercisePromptSurfaces(ideas: Bool, banner: Bool) async throws {
      let transport = HubTestTransport()
      await transport.prepare([(201, hubIdentityJSON())])
      let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
      defer {
        try? FileManager.default.removeItem(at: root)
        ShakeToShip.model = nil
      }
      await client.setActive(true)
      _ = try await client.identity()
      let response =
        #"{"id":"c0000000-0000-4000-8000-000000000001","kind":"text","question":"What would help?","impressionId":"d0000000-0000-4000-8000-000000000001"}"#
      await transport.prepare([(200, response)], suspend: true)
      let model = FeedbackHubModel(client: client, config: await client.config)
      model.ideas = [
        try JSONDecoder().decode(FeedbackIdea.self, from: Data(HubSnapshotFixtures.ideaJSON.utf8))
      ]
      ShakeToShip.model = model
      let host = UIHostingController(
        rootView: VStack {
          if banner { ShakeToShip.promptBanner() }
          if ideas { NavigationStack { FeedbackIdeasView(model: model) } }
        })
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      host.view.layoutIfNeeded()
      for _ in 0..<100 {
        if await transport.requests.count >= 2 { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      // Give both surface tasks time to enter while the transport is suspended.
      try await Task.sleep(for: .milliseconds(100))
      let reserved = await transport.requests.filter { $0.url!.path == "/prompts/next" }.count
      XCTAssertEqual(reserved, 1)
      await transport.resume()
      for _ in 0..<100 {
        if model.prompt != nil { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertEqual(model.prompt?.question, "What would help?")
      XCTAssertEqual(model.prompt?.impressionId, "d0000000-0000-4000-8000-000000000001")
      // A later foreground refresh shares the displayed reservation.
      await model.refreshPrompt()
      let completed = await transport.requests.count
      XCTAssertEqual(completed, 2)
      await client.setActive(false)
    }

    func testInboxDestinationKeepsDelayedDetailMounted() async throws {
      let transport = HubTestTransport()
      await transport.prepare([(201, hubIdentityJSON())])
      let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
      defer { try? FileManager.default.removeItem(at: root) }
      await client.setActive(true)
      _ = try await client.identity()
      await transport.prepare([(200, HubSnapshotFixtures.ideaJSON)], suspend: true)
      let model = FeedbackHubModel(client: client, config: await client.config)
      let host = UIHostingController(
        rootView: NavigationStack { FeedbackInboxIdea(model: model, id: "sample") })
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        window.rootViewController = nil
      }
      host.view.layoutIfNeeded()
      for _ in 0..<100 {
        if await transport.requests.count == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      let started = await transport.requests.count
      XCTAssertEqual(started, 2)
      await transport.resume()
      // Permit SwiftUI to mount children and run their tasks after the delayed response.
      try await Task.sleep(for: .milliseconds(200))
      let completed = await transport.requests.count
      XCTAssertEqual(completed, 2, "The destination must own exactly one detail request")
      XCTAssertEqual(model.selectedIdea?.id, "sample")
      XCTAssertFalse(model.detailLoading)
      XCTAssertNil(model.error)
      await client.setActive(false)
    }
  }
#endif
