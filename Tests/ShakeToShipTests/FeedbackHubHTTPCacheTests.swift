import Foundation
import Network
import Testing

@testable import ShakeToShip

/// Uses the production default transport, including Foundation's real HTTP cache.
struct FeedbackHubHTTPCacheTests {
  @Test func resetAndProjectChangeCannotReadAnotherReportersCachedInbox() async throws {
    let server = try HubCacheHTTPServer()
    let baseURL = try await server.start()
    defer { server.stop() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func client(_ project: String) throws -> FeedbackHubClient {
      try FeedbackHubClient(
        config: ShakeToShipConfig(
          app: "same-app", collectorURL: baseURL, secret: project, hub: [.inbox]),
        storage: FeedbackHubStorage(
          scope: project, root: root.appendingPathComponent(project),
          readIdentity: { nil }, writeIdentity: { _ in }))
    }
    let first = try client("project-a")
    await first.setActive(true)
    let before = try await first.decode(FeedbackInbox.self, path: "v2/inbox")
    #expect(before.messages.first?.payload.title == "project-a/reporter-1")
    try await first.reset()
    let after = try await first.decode(FeedbackInbox.self, path: "v2/inbox")
    #expect(after.messages.first?.payload.title == "project-a/reporter-2")
    let other = try client("project-b")
    await other.setActive(true)
    let changed = try await other.decode(FeedbackInbox.self, path: "v2/inbox")
    #expect(changed.messages.first?.payload.title == "project-b/reporter-3")
  }
}

/// A loopback collector deliberately omits credential Vary and permits HTTP caching.
/// The SDK must isolate private data even when a server or proxy permits caching.
private final class HubCacheHTTPServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "shaketoship.http-cache-test")
  private let lock = NSLock()
  private var identityNumber = 0

  init() throws { listener = try NWListener(using: .tcp, on: .any) }

  func start() async throws -> URL {
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      connection.start(queue: self.queue)
      self.receive(connection, previous: Data())
    }
    return try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.listener.stateUpdateHandler = nil
          continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)")!)
        case .failed(let error):
          self.listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func stop() { listener.cancel() }

  private func receive(_ connection: NWConnection, previous: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
      guard let self else { connection.cancel(); return }
      let all = previous + (data ?? Data())
      guard let header = String(data: all, encoding: .utf8), header.contains("\r\n\r\n") else {
        if done || error != nil { connection.cancel() }
        else { self.receive(connection, previous: all) }
        return
      }
      let body: String
      if header.hasPrefix("POST /identity ") {
        let number = self.lock.withLock {
          self.identityNumber += 1
          return self.identityNumber
        }
        let payload = Data("{\"exp\":4000000000,\"sub\":\"reporter-\(number)\"}".utf8).base64EncodedString()
        body = "{\"reporterId\":\"reporter-\(number)\",\"reporterToken\":\"rt1.\(payload).signature\"}"
      } else {
        let project = header.components(separatedBy: "\r\n")
          .first { $0.lowercased().hasPrefix("x-feedback-secret:") }?
          .components(separatedBy: ":").dropFirst().joined(separator: ":")
          .trimmingCharacters(in: .whitespaces) ?? "missing"
        let number = self.lock.withLock { self.identityNumber }
        body = "{\"messages\":[{\"id\":\"notice\",\"kind\":\"fixed\",\"ideaId\":null,\"createdAt\":\"2026-09-23T00:00:00Z\",\"payload\":{\"title\":\"\(project)/reporter-\(number)\"}}]}"
      }
      let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: public, max-age=3600\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
