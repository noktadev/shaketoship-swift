import Foundation
import Testing
@testable import AppUploads

@Suite struct MultipartUploaderTests {
  let capability = MultipartUploadCapabilities(version: 1, partSize: 10 * 1024 * 1024)

  private func source(extension fileExtension: String = "mov") throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("original." + fileExtension)
    FileManager.default.createFile(atPath: source.path, contents: nil)
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: UInt64(capability.partSize + 17))
    try handle.close()
    return (source, directory.appendingPathComponent("state"))
  }
  private func signed(_ token: String) -> URL { URL(string: "https://collector.test/upload/app/session/original.mov?token=\(token)")! }

  @Test func failedPartResumesAfterRelaunchAndRefreshesExpiredURLs() async throws {
    let (file, state) = try source()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = MultipartTestTransport(state: state, failingPart: 1)
    do {
      try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state, objectID: "tenant/original",
        signedURL: signed("old-ticket"), capabilities: capability, contentType: "video/quicktime")
      Issue.record("expected failed part")
    } catch {}
    #expect(FileManager.default.fileExists(atPath: file.path))
    let persisted = try JSONDecoder().decode(MultipartUploadState.self,
      from: Data(contentsOf: state.appendingPathComponent("state.json")))
    #expect(persisted.parts[2] != nil)
    #expect(persisted.parts[1] == nil)
    try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state, objectID: "tenant/original",
      signedURL: signed("renewed-ticket"), capabilities: capability, contentType: "video/quicktime")
    let seen = await transport.snapshot()
    #expect(seen.attempts == [1: 2, 2: 1])
    #expect(seen.startTickets == ["old-ticket", "renewed-ticket"])
    #expect(seen.resumeTokens == ["", "upload-token-1"])
    #expect(seen.partTokens.contains("upload-token-2"))
    #expect(seen.acknowledgedAfterCheckpoint)
    #expect(FileManager.default.fileExists(atPath: file.path), "the caller owns final session completion")
  }

  @Test func lostCompleteResponseUsesStatusWithoutRepeatingParts() async throws {
    let (file, state) = try source()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = MultipartTestTransport(state: state, loseCompletion: true)
    do {
      try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state, objectID: "tenant/original",
        signedURL: signed("first"), capabilities: capability, contentType: "video/quicktime")
      Issue.record("expected response loss")
    } catch {}
    #expect(FileManager.default.fileExists(atPath: file.path))
    try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state, objectID: "tenant/original",
      signedURL: signed("second"), capabilities: capability, contentType: "video/quicktime")
    let seen = await transport.snapshot()
    #expect(seen.attempts == [1: 1, 2: 1])
    #expect(seen.completeRequests == 1)
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func changedOriginalOrObjectCannotReuseParts() async throws {
    let (file, state) = try source()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = MultipartTestTransport(state: state, failingPart: 1)
    try? await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state, objectID: "tenant/original",
      signedURL: signed("first"), capabilities: capability, contentType: "video/quicktime")
    do {
      try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state, objectID: "tenant/original",
        signedURL: URL(string: "https://collector.test/upload/different.mov?token=new")!, capabilities: capability, contentType: "video/quicktime")
      Issue.record("wrong object accepted")
    } catch MultipartUploadError.originalChanged {} catch { Issue.record("unexpected error: \(error)") }
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 4)
    try handle.close()
    do {
      try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state, objectID: "tenant/original",
        signedURL: signed("second"), capabilities: capability, contentType: "video/quicktime")
      Issue.record("changed original accepted")
    } catch MultipartUploadError.originalChanged {} catch { Issue.record("unexpected error: \(error)") }
    #expect(await transport.snapshot().startTickets.count == 1)
  }

  @Test func sameSizeOverwriteWithPreservedModificationDateCannotReuseParts() async throws {
    let (file, state) = try source()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let before = try MultipartUploadState.Original.read(file)
    let transport = MultipartTestTransport(state: state, failingPart: 1)
    try? await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state,
      objectID: "tenant/original", signedURL: signed("first"), capabilities: capability)
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: Data([1]))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: before.modifiedAt], ofItemAtPath: file.path)
    do {
      try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state,
        objectID: "tenant/original", signedURL: signed("second"), capabilities: capability)
      Issue.record("changed bytes accepted")
    } catch MultipartUploadError.originalChanged {} catch { Issue.record("unexpected error: \(error)") }
    #expect(await transport.snapshot().startTickets.count == 1)
  }

  @Test func arbitraryPDFUsesTheSameEngineAndPreservesOriginal() async throws {
    let (file, state) = try source(extension: "pdf")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = MultipartTestTransport(state: state)
    try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state, objectID: "tenant/original",
      signedURL: URL(string: "https://collector.test/upload/tenant/document.pdf?token=auth")!, capabilities: capability, contentType: "application/pdf",
      scheduling: .backgroundQueued)
    #expect(await transport.snapshot().attempts == [1: 1, 2: 1])
    #expect(await transport.snapshot().contentTypes == ["application/pdf"])
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func changedOriginalDuringCompleteResponseIsRetained() async throws {
    let (file, state) = try source()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = MultipartTestTransport(state: state, mutateOnComplete: file)
    do {
      try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state,
        objectID: "tenant/original", signedURL: signed("ticket"), capabilities: capability, contentType: "video/quicktime")
      Issue.record("changed source accepted")
    } catch MultipartUploadError.originalChanged {} catch { Issue.record("unexpected error: \(error)") }
    #expect(FileManager.default.fileExists(atPath: file.path))
    let saved = try JSONDecoder().decode(MultipartUploadState.self, from: Data(contentsOf: state.appendingPathComponent("state.json")))
    #expect(!saved.complete)
  }

  @Test func latestStatusOverridesStaleStartCompletion() async throws {
    let (file, state) = try source()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = MultipartTestTransport(state: state, staleStartComplete: true)
    try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state,
      objectID: "tenant/original", signedURL: signed("ticket"), capabilities: capability)
    let seen = await transport.snapshot()
    #expect(seen.attempts == [1: 1, 2: 1])
    #expect(seen.completeRequests == 1)
  }

  @Test func advertisedLimitRejectsSourceWithoutCreatingAnUpload() async throws {
    let (file, state) = try source()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let transport = MultipartTestTransport(state: state)
    do {
      try await MultipartUploader(transport: transport).upload(sourceURL: file, stateDirectory: state,
        objectID: "tenant/original", signedURL: signed("ticket"),
        capabilities: MultipartUploadCapabilities(version: 1, partSize: capability.partSize, maximumBytes: 1024))
      Issue.record("server limit ignored")
    } catch MultipartUploadError.sourceTooLarge(let limit) { #expect(limit == 1024) }
    #expect(await transport.snapshot().startTickets.isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func stableTransferIdentityExcludesTicketsButSeparatesUploadsAndParts() throws {
    let first = try MultipartUploader.transferID(signedURL: signed("secret-a"), objectID: "tenant/original", uploadID: "u1", partNumber: 1)
    #expect(first == (try MultipartUploader.transferID(signedURL: signed("secret-b"), objectID: "tenant/original", uploadID: "u1", partNumber: 1)))
    #expect(!first.contains("secret"))
    #expect(first != (try MultipartUploader.transferID(signedURL: signed("secret-a"), objectID: "tenant/original", uploadID: "u2", partNumber: 1)))
    #expect(first != (try MultipartUploader.transferID(signedURL: signed("secret-a"), objectID: "tenant/original", uploadID: "u1", partNumber: 2)))
  }
}

private actor MultipartTestTransport: UploadTransport {
  struct Snapshot: Sendable {
    var attempts: [Int: Int] = [:]
    var startTickets: [String] = []
    var resumeTokens: [String] = []
    var partTokens: [String] = []
    var completeRequests = 0
    var contentTypes: [String] = []
    var acknowledgedAfterCheckpoint = true
  }
  let state: URL
  var failingPart: Int?
  var loseCompletion: Bool
  var complete = false
  let mutateOnComplete: URL?
  let staleStartComplete: Bool
  var seen = Snapshot()
  init(state: URL, failingPart: Int? = nil, loseCompletion: Bool = false, mutateOnComplete: URL? = nil, staleStartComplete: Bool = false) {
    self.state = state; self.failingPart = failingPart; self.loseCompletion = loseCompletion
    self.mutateOnComplete = mutateOnComplete
    self.staleStartComplete = staleStartComplete
  }
  func snapshot() -> Snapshot { seen }
  func query(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  }
  func response(_ request: URLRequest, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let query = query(request)
    switch query["multipart"] {
    case "start":
      seen.startTickets.append(query["token"] ?? "")
      let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      seen.resumeTokens.append(body["resumeToken"] as? String ?? "")
      seen.contentTypes.append(body["contentType"] as? String ?? "")
      return response(request, "{\"uploadId\":\"upload-1\",\"uploadToken\":\"upload-token-\(seen.startTickets.count)\",\"partSize\":10485760,\"status\":\"\((complete || staleStartComplete) ? "complete" : "uploading")\"}")
    case "status": return response(request, "{\"status\":\"\(complete ? "complete" : "uploading")\"}")
    case "complete":
      seen.completeRequests += 1
      complete = true
      if let mutateOnComplete { try Data("changed".utf8).write(to: mutateOnComplete) }
      if loseCompletion { loseCompletion = false; throw URLError(.networkConnectionLost) }
      return response(request, #"{"status":"complete"}"#)
    default: throw URLError(.badURL)
    }
  }
  func upload(_ request: URLRequest, fromFile file: URL, transferID: String) async throws -> (Data, HTTPURLResponse) {
    let query = query(request)
    let number = Int(query["partNumber"]!)!
    seen.attempts[number, default: 0] += 1
    seen.partTokens.append(query["token"] ?? "")
    #expect(transferID.contains("upload-1"))
    #expect(FileManager.default.fileExists(atPath: file.path))
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
    #expect(size == (number == 1 ? 10 * 1024 * 1024 : 17))
    if failingPart == number { failingPart = nil; return response(request, "{}", status: 401) }
    return response(request, "{\"partNumber\":\(number),\"etag\":\"etag-\(number)\",\"receipt\":\"receipt-\(number)\"}")
  }
  func acknowledge(transferID: String, file: URL) async {
    let number = Int(file.lastPathComponent.replacingOccurrences(of: "part-", with: ""))!
    let saved = try? JSONDecoder().decode(MultipartUploadState.self,
      from: Data(contentsOf: state.appendingPathComponent("state.json")))
    seen.acknowledgedAfterCheckpoint = seen.acknowledgedAfterCheckpoint && saved?.parts[number] != nil
  }
}
