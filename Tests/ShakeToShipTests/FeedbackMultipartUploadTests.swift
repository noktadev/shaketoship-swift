import Foundation
import Testing
@testable import ShakeToShip

@Suite struct FeedbackMultipartUploadTests {
  private func fixture(name: String, legacyFailure: Bool = false) throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-multipart-\(UUID())")
    let dir = root.appendingPathComponent("session")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let original = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: original.path, contents: nil)
    let handle = try FileHandle(forWritingTo: original)
    try handle.truncate(atOffset: 10 * 1024 * 1024 + 17)
    try handle.close()
    try Data().write(to: dir.appendingPathComponent(feedbackConfirmedMarker))
    if legacyFailure {
      try Data(#"{"version":1,"statusCode":413,"recoveredCopyRejected":true}"#.utf8)
        .write(to: dir.appendingPathComponent(".upload-failure.json"))
    }
    return (root, original)
  }
  private func uploader(_ root: URL, _ transport: MultipartFeedbackTransport,
                        _ compressor: MultipartRejectCompressor) -> FeedbackUploader {
    FeedbackUploader(config: ShakeToShipConfig(app: "app", collectorURL: URL(string: "https://collector.test")!, secret: "secret"),
      transport: transport, fileManager: .default, outboxRoot: root, videoCompressor: compressor)
  }

  @Test func legacySizeFailureResumesOriginalPartsAndRetainsItUntilSessionCompletion() async throws {
    let (root, original) = try fixture(name: "recording.mov", legacyFailure: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = MultipartFeedbackTransport(failPart: 1, failSentinel: true)
    let compressor = MultipartRejectCompressor()
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .retryableFailure)
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(uploader(root, transport, compressor).retainedRecordings().first?.originalFiles.map { $0.resolvingSymlinksInPath() } == [original.resolvingSymlinksInPath()])
    #expect(await transport.stats().sentinels == 0)
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .retryableFailure)
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .uploaded)
    let stats = await transport.stats()
    #expect(stats.parts == [1: 2, 2: 1])
    #expect(stats.sentinels == 2)
    #expect(stats.completeBeforeSentinel)
    #expect(await compressor.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: original.deletingLastPathComponent().path))
  }

  @Test func serverLimitUsesRecoveryAndRetainsOriginalWhenCompressionFails() async throws {
    let (root, original) = try fixture(name: "recording.mov")
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = MultipartFeedbackTransport(maximumBytes: 1024)
    let compressor = MultipartRejectCompressor()
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .recordingTooLarge)
    #expect(await compressor.calls == 1)
    #expect(await transport.stats().starts == 0)
    #expect(FileManager.default.fileExists(atPath: original.path))
    #expect(uploader(root, transport, compressor).retainedRecordings().first?.originalFiles.map { $0.resolvingSymlinksInPath() } == [original.resolvingSymlinksInPath()])
  }

  @Test func largeJPEGUsesLegacyPUTEvenWhenMultipartIsAdvertised() async throws {
    let name = FeedbackAttachmentNaming.attachmentFile(index: 0, kind: .image)
    let (root, original) = try fixture(name: name)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = MultipartFeedbackTransport()
    let compressor = MultipartRejectCompressor()
    #expect(await uploader(root, transport, compressor).upload(sessionId: "session") == .uploaded)
    let stats = await transport.stats()
    #expect(stats.starts == 0)
    #expect(stats.parts.isEmpty)
    #expect(stats.legacyFiles.contains(name))
    #expect(!FileManager.default.fileExists(atPath: original.path))
  }
}

private actor MultipartRejectCompressor: FeedbackVideoCompressing {
  var calls = 0
  func compress(source: URL, destination: URL, maximumBytes: Int) async throws {
    calls += 1
    throw URLError(.cannotCreateFile)
  }
}

private actor MultipartFeedbackTransport: FeedbackTransport {
  struct Stats: Sendable {
    var parts: [Int: Int] = [:]
    var starts = 0
    var sentinels = 0
    var completeBeforeSentinel = true
    var legacyFiles: [String] = []
  }
  var failPart: Int?
  var failSentinel: Bool
  var complete = false
  let maximumBytes: Int?
  var seen = Stats()
  init(failPart: Int? = nil, failSentinel: Bool = false, maximumBytes: Int? = nil) {
    self.failPart = failPart; self.failSentinel = failSentinel
    self.maximumBytes = maximumBytes
  }
  func stats() -> Stats { seen }
  func query(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  }
  func response(_ request: URLRequest, _ object: [String: Any], status: Int = 200) throws -> (Data, HTTPURLResponse) {
    (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if request.url?.lastPathComponent == "presign" {
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      let files = body["files"] as! [String]
      let urls = Dictionary(uniqueKeysWithValues: files.map { ($0, "https://collector.test/upload?token=fresh-ticket&file=\($0)") })
      var capability = ["version": 1, "partSize": 10485760]
      if let maximumBytes { capability["maximumBytes"] = maximumBytes }
      return try response(request, ["urls": urls, "multipart": capability])
    }
    switch query(request)["multipart"] {
    case "start":
      seen.starts += 1
      return try response(request, ["uploadId": "upload-1", "uploadToken": "renewed-\(seen.starts)", "partSize": 10485760,
                                    "status": complete ? "complete" : "uploading"])
    case "status": return try response(request, ["status": complete ? "complete" : "uploading"])
    case "complete": complete = true; return try response(request, ["status": "complete"])
    default: throw URLError(.badURL)
    }
  }
  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
    let fields = query(request)
    if fields["multipart"] == "part", let number = Int(fields["partNumber"] ?? "") {
      seen.parts[number, default: 0] += 1
      if failPart == number { failPart = nil; return try response(request, [:], status: 503) }
      return try response(request, ["partNumber": number, "etag": "etag-\(number)", "receipt": "receipt-\(number)"])
    }
    if file.lastPathComponent == "complete.json" {
      seen.sentinels += 1
      seen.completeBeforeSentinel = seen.completeBeforeSentinel && (seen.starts == 0 || complete)
      if failSentinel { failSentinel = false; return try response(request, [:], status: 503) }
    } else { seen.legacyFiles.append(file.lastPathComponent) }
    return try response(request, [:])
  }
}
