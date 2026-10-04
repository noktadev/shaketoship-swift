import Foundation
import Testing

@testable import ShakeToShip

/// Wire fixtures mirror PR1474's capture DTO and generic ordinary-report notice.
struct FeedbackMergedCaptureContractTests {
  private let databaseID = "a0000000-0000-4000-8000-000000000001"
  private let ideaID = "b0000000-0000-4000-8000-000000000001"

  @Test func retryKeepsRootManifestPurposeReporterAndDatabaseReference() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("external-capture")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("private text".utf8).write(to: dir.appendingPathComponent("note.txt"))
    await client.setActive(true)
    try await client.bindCapture(in: dir, purpose: .idea(ideaID))
    let binding = try Data(contentsOf: dir.appendingPathComponent(".reporter-binding.json"))
    let receipt = "{\"sessionRecordId\":\"\(databaseID)\",\"urls\":{\"note.txt\":\"https://upload.test/opaque/note\",\"complete.json\":\"https://upload.test/opaque/complete\"}}"
    await transport.prepare([(201, hubIdentityJSON()), (200, receipt), (200, ""), (503, "")])
    let config = await client.config
    let uploader = FeedbackUploader(
      config: config, transport: transport, fileManager: .default, outboxRoot: root,
      hubClient: client)
    #expect(await uploader.upload(sessionId: "external-capture") == .retryableFailure)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("note.txt").path))
    let original = try #require(try await client.ownedSessions().first)
    #expect(original.id == databaseID)
    #expect(try await client.attachableReports().isEmpty)
    await transport.prepare([(200, receipt), (200, "")])
    // Recreate the uploader after partial success, as an outbox retry does.
    let retry = FeedbackUploader(
      config: config, transport: transport, fileManager: .default, outboxRoot: root,
      hubClient: client)
    #expect(try Data(contentsOf: dir.appendingPathComponent(".reporter-binding.json")) == binding)
    #expect(await retry.upload(sessionId: "external-capture") == .uploaded)
    let requests = await transport.requests
    let presigns = requests.filter { $0.url?.path == "/presign" }
    #expect(presigns.count == 2)
    let first = try JSONSerialization.jsonObject(with: presigns[0].httpBody!) as! [String: Any]
    let second = try JSONSerialization.jsonObject(with: presigns[1].httpBody!) as! [String: Any]
    let manifest = ["startedAt", "appBundleId", "sdkVersion", "hasNarration", "hasAppAudio", "capSeconds", "state", "transcribe"]
    for key in manifest {
      #expect(first[key] != nil)
      #expect(NSDictionary(dictionary: [key: first[key]!]).isEqual(to: [key: second[key]!]))
    }
    for body in [first, second] {
      #expect(body["manifest"] == nil)
      #expect(body["userRef"] == nil)
      #expect(body["sessionId"] as? String == "external-capture")
      #expect(body["purpose"] as? [String: String] == ["kind": "idea", "ideaId": ideaID])
      #expect(body["appBundleId"] as? String == config.app)
      #expect(body["sdkVersion"] as? String == "2.0.0")
      #expect(body["hasNarration"] as? Bool == false)
      #expect(body["hasAppAudio"] as? Bool == false)
      #expect(body["capSeconds"] as? Double == config.maxDuration)
      #expect(body["state"] as? String == "finished")
      #expect(body["transcribe"] as? Bool == config.transcription)
      #expect(ISO8601DateFormatter().date(from: body["startedAt"] as! String) != nil)
    }
    #expect(second["files"] as? [String] == ["complete.json"])
    #expect(presigns.allSatisfy { $0.value(forHTTPHeaderField: "x-feedback-secret") == "project-secret" })
    #expect(presigns[0].value(forHTTPHeaderField: "x-reporter-token") != nil)
    #expect(presigns[0].value(forHTTPHeaderField: "x-reporter-token") == presigns[1].value(forHTTPHeaderField: "x-reporter-token"))
    let stored = try #require(try await client.ownedSessions().first)
    #expect(stored.id == original.id)
    #expect(stored.generation == original.generation)
    #expect(stored.reporterId == original.reporterId)
    #expect(stored.purpose == original.purpose)
    #expect(!requests.contains { $0.url?.path.contains("/details") == true })
  }

  @Test func omittedDatabaseIDNeverUsesSignedURLAsOwnershipProof() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("external-capture")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("text".utf8).write(to: dir.appendingPathComponent("note.txt"))
    await client.setActive(true)
    try await client.bindCapture(in: dir)
    await transport.prepare([
      (201, hubIdentityJSON()),
      (200, "{\"urls\":{\"note.txt\":\"https://upload.test/\(databaseID)/note\",\"complete.json\":\"https://upload.test/\(databaseID)/complete\"}}"),
      (200, ""), (200, ""),
    ])
    let uploader = FeedbackUploader(
      config: await client.config, transport: transport, fileManager: .default,
      outboxRoot: root, hubClient: client)
    #expect(await uploader.upload(sessionId: "external-capture") == .uploaded)
    #expect(try await client.attachableReports().isEmpty)
  }

  @Test(arguments: ["missing", "foreign-scope", "old-generation", "inactive", "disabled", "legacy-enabled"])
  func invalidBindingOrClosedGateNeverStartsOrReassignsCapture(_ condition: String) async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("private".utf8).write(to: dir.appendingPathComponent("note.txt"))
    await client.setActive(true)
    if condition != "missing" {
      let binding = FeedbackCaptureBinding(
        scope: condition == "foreign-scope" ? "other-project" : "test",
        generation: condition == "old-generation" ? UUID() : await client.generation,
        purpose: .report)
      try JSONEncoder().encode(binding).write(to: dir.appendingPathComponent(FeedbackCaptureBinding.filename))
    }
    var config = await client.config
    if condition == "inactive" { await client.setActive(false) }
    if condition == "legacy-enabled" {
      config = ShakeToShipConfig(app: config.app, collectorURL: config.collectorURL,
        secret: config.secret, hub: config.hub, allowsLegacyCaptures: true)
      await client.setActive(false)
    }
    if condition == "disabled" {
      // The bound capture must not fall back to the legacy transport when the hub is removed.
      config = ShakeToShipConfig(app: config.app, collectorURL: config.collectorURL, secret: config.secret)
    }
    let uploader = FeedbackUploader(
      config: config, transport: transport, fileManager: .default, outboxRoot: root,
      hubClient: condition == "disabled" ? nil : client)
    for _ in 0..<2 {
      #expect(await uploader.upload(sessionId: "capture") != .uploaded)
    }
    #expect(await transport.requests.isEmpty)
  }
}
