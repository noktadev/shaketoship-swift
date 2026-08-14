import Foundation
import Testing

@testable import ShakeToShip

@Suite struct DegradationNetworkTests {
  @Test func offlineReportStaysQueuedAndRetriesWhenNetworkReturns() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sts-offline-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appendingPathComponent("session", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let session = FeedbackSession(
      session_id: "session", app: "test", build: "1",
      started_at: "2026-08-14T00:00:00Z", events: [])
    try JSONEncoder().encode(session).write(to: dir.appendingPathComponent("events.json"))
    try Data().write(to: dir.appendingPathComponent(feedbackConfirmedMarker))

    let transport = DegradationNetworkTransport()
    let uploader = FeedbackUploader(
      config: ShakeToShipConfig(
        app: "test", collectorURL: URL(string: "https://collector.example.com")!, secret: "s"),
      transport: transport, fileManager: .default, outboxRoot: root)

    let sentOffline = await uploader.flush(sessionId: "session")

    #expect(sentOffline == false)
    #expect(FileManager.default.fileExists(atPath: dir.path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("events.json").path))

    let retry = await uploader.retryOutbox()

    #expect(retry == OutboxSweepResult(flushed: 1, queued: 0, purged: 0))
    #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    #expect(await transport.presignAttempts == 2)
  }
}

private actor DegradationNetworkTransport: FeedbackTransport {
  private(set) var presignAttempts = 0

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    presignAttempts += 1
    if presignAttempts == 1 {
      throw URLError(.notConnectedToInternet)
    }
    let body = Data(
      #"{"urls":{"events.json":"https://r2.example.com/events","complete.json":"https://r2.example.com/complete"}}"#.utf8)
    return (body, response(for: request, status: 200))
  }

  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (
    Data, HTTPURLResponse
  ) {
    _ = try Data(contentsOf: file)
    return (Data(), response(for: request, status: 200))
  }

  private func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
  }
}
