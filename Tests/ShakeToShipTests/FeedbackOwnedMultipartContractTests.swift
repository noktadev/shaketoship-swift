import Foundation
import Testing

@testable import ShakeToShip

struct FeedbackOwnedMultipartContractTests {
  @Test func renewalRetainsOpaqueReceiptsAndOwnershipAfterAdmissionFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = OwnedMultipartTransport()
    let config = ShakeToShipConfig(
      app: "com.example.test", collectorURL: URL(string: "https://collector.test")!,
      secret: "project-secret", hub: [.ideas])
    // Use the real hub request/transfer gates around the wire fixture.
    let storage = FeedbackHubStorage(
      scope: "multipart", root: root.appendingPathComponent("identity"),
      readIdentity: { nil }, writeIdentity: { _ in })
    let owner = try FeedbackHubClient(config: config, storage: storage, transport: transport)
    await owner.setActive(true)
    let capture = root.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    let source = capture.appendingPathComponent("recording.mov")
    FileManager.default.createFile(atPath: source.path, contents: nil)
    let file = try FileHandle(forWritingTo: source)
    try file.truncate(atOffset: 10 * 1024 * 1024 + 17)
    try file.close()
    try Data().write(to: capture.appendingPathComponent(feedbackConfirmedMarker))
    try await owner.bindCapture(in: capture)
    let binding = try Data(contentsOf: capture.appendingPathComponent(FeedbackCaptureBinding.filename))
    let uploader = FeedbackUploader(
      config: config, transport: transport, fileManager: .default, outboxRoot: root, hubClient: owner)
    #expect(await uploader.upload(sessionId: "capture") == .retryableFailure)
    let stateURL = capture.appendingPathComponent(".multipart-recording.mov/state.json")
    let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    #expect(state["resumeToken"] as? String == "opaque+grant/1&=")
    #expect(try Data(contentsOf: capture.appendingPathComponent(FeedbackCaptureBinding.filename)) == binding)
    let owned = try #require(try await owner.attachableReports().first)
    #expect(owned.id == OwnedMultipartTransport.databaseID)
    #expect(await uploader.upload(sessionId: "capture") == .uploaded)
    #expect(try await owner.attachableReports().first?.generation == owned.generation)
    let requests = await transport.requests
    let starts = requests.filter { OwnedMultipartTransport.query($0)["multipart"] == "start" }
    #expect(starts.count == 2)
    let renewal = try JSONSerialization.jsonObject(with: starts[1].httpBody!) as! [String: Any]
    #expect(renewal["resumeToken"] as? String == "opaque+grant/1&=")
    #expect(OwnedMultipartTransport.query(starts[1])["token"] == "original-2")
    let complete = try #require(requests.first { OwnedMultipartTransport.query($0)["multipart"] == "complete" })
    let body = try JSONSerialization.jsonObject(with: complete.httpBody!) as! [String: Any]
    let parts = body["parts"] as! [[String: Any]]
    #expect(parts.map { $0["receipt"] as! String } == ["opaque+receipt/1&=", "opaque+receipt/2&="])
    #expect(await transport.parts == [1: 1, 2: 2])
    #expect(OwnedMultipartTransport.query(complete)["token"] == "opaque+grant/2&=")
    #expect(requests.last?.url?.lastPathComponent == "complete.json")
    let presigns = requests.filter { $0.url?.path == "/presign" }
    #expect(presigns.count == 2)
    #expect(presigns.allSatisfy { $0.value(forHTTPHeaderField: "x-feedback-secret") == "project-secret" })
    #expect(presigns[0].value(forHTTPHeaderField: "x-reporter-token") == presigns[1].value(forHTTPHeaderField: "x-reporter-token"))
  }

  @Test func resetBlocksEveryPreviouslyGrantedMultipartAction() async throws {
    let transport = HubTestTransport()
    let (owner, root, _) = try FeedbackHubClientTests().fixture(transport: transport)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    await owner.setActive(true)
    try await owner.bindCapture(in: root)
    let binding = try #require(try FeedbackCaptureBinding.read(in: root))
    let adapter = FeedbackIdentityTransport(client: owner, binding: binding)
    try await owner.reset()
    for (action, method) in [("start", "POST"), ("status", "GET"), ("part", "PUT"), ("complete", "POST"), ("abort", "DELETE")] {
      var request = URLRequest(url: URL(string: "https://collector.test/upload?multipart=\(action)&token=old-opaque-grant&uploadId=old")!)
      request.httpMethod = method
      await #expect(throws: FeedbackHubError.self) { try await adapter.perform(request) }
    }
    #expect(await transport.requests.isEmpty)
  }
}

private actor OwnedMultipartTransport: FeedbackTransport {
  static let databaseID = "d0000000-0000-4000-8000-000000000001"
  var requests: [URLRequest] = []
  var parts: [Int: Int] = [:]
  private var presigns = 0
  private var starts = 0
  static func query(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  }
  private func response(_ request: URLRequest, _ body: [String: Any], status: Int = 200) throws -> (Data, HTTPURLResponse) {
    (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if request.url?.path == "/identity" {
      return (Data(hubIdentityJSON().utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }
    if request.url?.path == "/presign" {
      presigns += 1
      return try response(request, [
        "sessionRecordId": Self.databaseID,
        "urls": ["recording.mov": "https://collector.test/upload?token=original-\(presigns)", "complete.json": "https://collector.test/complete.json?token=sentinel"],
        "multipart": ["version": 1, "partSize": 10485760, "maximumBytes": 209715200],
      ])
    }
    let query = Self.query(request)
    switch query["multipart"] {
    case "start":
      starts += 1
      return try response(request, ["uploadId": "opaque/upload&=", "uploadToken": "opaque+grant/\(starts)&=", "partSize": 10485760, "status": "uploading"])
    case "status": return try response(request, ["status": "uploading"])
    case "part":
      let number = Int(query["partNumber"]!)!
      parts[number, default: 0] += 1
      if number == 2 && parts[number] == 1 {
        return try response(request, ["code": "multipart_storage_failure"], status: 503)
      }
      #expect(request.value(forHTTPHeaderField: "Content-Length") == (number == 1 ? "10485760" : "17"))
      return try response(request, ["partNumber": number, "etag": "etag-\(number)", "receipt": "opaque+receipt/\(number)&="])
    case "complete": return try response(request, ["status": "complete"])
    default: return try response(request, [:])
    }
  }
  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
    try await perform(request)
  }
}
