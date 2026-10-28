#if canImport(Network)
import Foundation
import Network
import Testing
@testable import ShakeToShip

struct FeedbackSupportSocketTests {
  @Test func upgradeUsesHeadersAndAnIdleBudgetLongerThanServerRenewal() async throws {
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    await transport.prepare([(200, hubIdentityJSON())])
    let request = try await client.supportSocketRequest()
    #expect(request.url?.scheme == "wss")
    #expect(request.timeoutInterval > 60)
    #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    #expect(request.url?.query?.contains("token") == false)
    #expect(request.url?.query?.contains("secret") == false)
  }

  /// Explicit slow gate: real URLSession + local Network WebSocket; no external service.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["STS_SOCKET_IDLE_TEST"] == "1"))
  func realSocketRemainsOpenAfterSixtySecondsWithoutApplicationFrames() async throws {
    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    let listener = try NWListener(using: parameters, on: .any)
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      Self.receive(connection)
    }
    let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
      listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port {
          listener.stateUpdateHandler = nil
          continuation.resume(returning: port.rawValue)
        } else if case .failed(let error) = state {
          listener.stateUpdateHandler = nil
          continuation.resume(throwing: error)
        }
      }
      listener.start(queue: .global())
    }
    defer { listener.cancel() }
    let transport = HubTestTransport()
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    await client.setActive(true)
    await transport.prepare([(200, hubIdentityJSON())])
    var request = try await client.supportSocketRequest()
    // Only the test redirects the authenticated request to a local plain socket.
    request.url = URL(string: "ws://127.0.0.1:\(port)")!
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.resume()
    // The production subscription keeps a receive pending while the channel is idle.
    let receiver = Task { try await socket.receive() }
    defer {
      receiver.cancel()
      socket.cancel(with: .normalClosure, reason: nil)
    }
    try await Self.ping(socket)
    try await Task.sleep(for: .seconds(65))
    try await Self.ping(socket)
    #expect(socket.state == .running)
  }
  private static func receive(_ connection: NWConnection) {
    connection.receiveMessage { _, _, _, error in
      if error != nil { connection.cancel() }
      else { receive(connection) }
    }
  }
  private static func ping(_ socket: URLSessionWebSocketTask) async throws {
    let deadline = Task {
      do { try await Task.sleep(for: .seconds(10)) } catch { return }
      socket.cancel(with: .goingAway, reason: nil)
    }
    defer { deadline.cancel() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      socket.sendPing { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }
}
#endif
