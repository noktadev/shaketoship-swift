import Foundation
import Testing

@testable import ShakeToShip

struct FeedbackCaptureIdentityTests {
  @Test func offlineCaptureBeforeExchangeBindsAtCreationAndCarriesPurpose() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    let dir = root.appendingPathComponent("external")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("private evidence".utf8).write(to: dir.appendingPathComponent("note.txt"))
    await client.setActive(true)
    try await client.bindCapture(in: dir, purpose: .idea("idea"))
    await transport.prepare([
      (201, hubIdentityJSON()),
      (
        200,
        #"{"sessionRecordId":"database-id","urls":{"note.txt":"https://upload.test/note","complete.json":"https://upload.test/complete"}}"#
      ), (200, ""), (200, ""),
    ])
    let uploader = FeedbackUploader(
      config: await client.config, transport: transport, fileManager: .default, outboxRoot: root,
      hubClient: client)
    #expect(await uploader.upload(sessionId: "external") == .uploaded)
    let requests = await transport.requests
    let presign = try #require(requests.first { $0.url?.path == "/presign" })
    #expect(presign.value(forHTTPHeaderField: "x-reporter-token") != nil)
    let body = try JSONSerialization.jsonObject(with: presign.httpBody!) as! [String: Any]
    #expect(body["userRef"] == nil)
    #expect((body["purpose"] as? [String: String])?["ideaId"] == "idea")
    #expect(try await client.ownedSessions().first?.id == "database-id")
    #expect(!requests.contains { $0.url?.path.contains("details") == true })
  }
  @Test func resetBeforePresignAndRetryRejectOldCapture() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    let outbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outbox)
    }
    let dir = outbox.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: dir.appendingPathComponent("note.txt"))
    await client.setActive(true)
    try await client.bindCapture(in: dir)
    try await client.reset()
    let uploader = FeedbackUploader(
      config: await client.config, transport: transport, fileManager: .default, outboxRoot: outbox,
      hubClient: client)
    #expect(await uploader.upload(sessionId: "external") == .rejected(statusCode: 403))
    #expect(await uploader.upload(sessionId: "external") == .rejected(statusCode: 403))
    #expect(await transport.requests.isEmpty)
  }
  @Test func resetDuringIssuedPresignCannotSaveIdOrUpload() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    let outbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outbox)
    }
    let dir = outbox.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: dir.appendingPathComponent("note.txt"))
    await client.setActive(true)
    try await client.bindCapture(in: dir)
    _ = try await client.identity()
    await transport.prepare(
      [
        (
          200,
          #"{"sessionRecordId":"old-id","urls":{"note.txt":"https://upload.test/note","complete.json":"https://upload.test/complete"}}"#
        )
      ], suspend: true)
    let uploader = FeedbackUploader(
      config: await client.config, transport: transport, fileManager: .default, outboxRoot: outbox,
      hubClient: client)
    let task = Task { await uploader.upload(sessionId: "external") }
    while await transport.requests.count < 2 { await Task.yield() }
    try await client.reset()
    await transport.resume()
    #expect(await task.value == .rejected(statusCode: 403))
    #expect(try await client.ownedSessions().isEmpty)
    #expect(await transport.requests.count == 2)
  }
}

extension FeedbackCaptureIdentityTests {
  @Test func resetCancelsIssuedTransferAndRejectsItsLateReceipt() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    await client.setActive(true)
    try await client.bindCapture(in: root)
    let binding = try #require(try FeedbackCaptureBinding.read(in: root))
    await transport.prepare([(200, "complete")], suspend: true)
    let adapter = FeedbackIdentityTransport(client: client, binding: binding)
    #expect(!adapter.supportsBackgroundUploads)
    let transfer = Task {
      try await adapter.upload(
        URLRequest(url: URL(string: "https://upload.test/complete")!), fromFile: root)
    }
    while await transport.requests.isEmpty { await Task.yield() }
    try await client.reset()
    await transport.resume()
    await #expect(throws: FeedbackHubError.self) { try await transfer.value }
    await #expect(throws: FeedbackHubError.self) {
      try await adapter.perform(
        URLRequest(url: URL(string: "https://upload.test/multipart/complete")!))
    }
    #expect(await transport.requests.count == 1)
  }
  @Test @MainActor func oldCaptureCannotReachRecoveryOrExportAfterReset() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    let capture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: capture)
      ShakeToShip.model = nil
    }
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    await client.setActive(true)
    try await client.bindCapture(in: capture)
    ShakeToShip.model = FeedbackHubModel(client: client, config: await client.config)
    #expect(await ShakeToShip.canAccessCapture(in: capture))
    try await ShakeToShip.resetIdentity()
    #expect(!(await ShakeToShip.canAccessCapture(in: capture)))
    let original = capture.appendingPathComponent("recording.mov")
    try Data("old private recording".utf8).write(to: original)
    let recording = FeedbackRetainedRecording(
      sessionId: "old", originalFiles: [original], createdAt: Date())
    await #expect(throws: FeedbackHubError.self) {
      try await FeedbackRecordingExportCopy.prepare(recording)
    }
  }
}

extension FeedbackCaptureIdentityTests {
  @Test func ownedCaptureNotFoundStopsRetryWithoutChangingPurpose() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON()), (404, "Not found")])
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("private".utf8).write(to: dir.appendingPathComponent("note.txt"))
    await client.setActive(true)
    try await client.bindCapture(in: dir, purpose: .idea("hidden"))
    let uploader = FeedbackUploader(
      config: await client.config, transport: transport, fileManager: .default, outboxRoot: root,
      hubClient: client)
    #expect(await uploader.upload(sessionId: "capture") == .rejected(statusCode: 404))
    #expect(await uploader.upload(sessionId: "capture") == .rejected(statusCode: 404))
    #expect(await transport.requests.count == 2)
    #expect(try FeedbackCaptureBinding.read(in: dir)?.purpose == .idea("hidden"))
  }
}

extension FeedbackCaptureIdentityTests {
  @Test func existingReportAttachmentRejectsIdeaCapturesAndResetReferences() async throws {
    let transport = HubTestTransport()
    await transport.prepare([(201, hubIdentityJSON())])
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    let reporter = try await client.identity()
    let generation = await client.generation
    let report = FeedbackCaptureBinding(scope: "test", generation: generation, purpose: .report)
    let idea = FeedbackCaptureBinding(scope: "test", generation: generation, purpose: .idea("idea"))
    try await client.saveSessionRecord(
      "report-database-id", captureId: "external-report", binding: report, reporter: reporter)
    try await client.saveSessionRecord(
      "idea-database-id", captureId: "external-idea", binding: idea, reporter: reporter)
    await #expect(throws: FeedbackHubError.self) {
      try await client.attachExistingReport("idea-database-id", to: "idea")
    }
    try await client.attachExistingReport("report-database-id", to: "idea")
    let request = try #require(await transport.requests.last)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
    #expect(body == ["app": "com.example.test", "sessionId": "report-database-id"])
    #expect(request.value(forHTTPHeaderField: "x-reporter-token") == reporter.reporterToken)
    try await client.reset()
    let count = await transport.requests.count
    await #expect(throws: FeedbackHubError.self) {
      try await client.attachExistingReport("report-database-id", to: "idea")
    }
    #expect(await transport.requests.count == count)
  }
}
