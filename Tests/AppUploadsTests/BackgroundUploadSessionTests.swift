import Foundation
import XCTest
@testable import AppUploads

final class BackgroundUploadSessionTests: XCTestCase {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  func test_completedResponseSurvivesRelaunchAndTokenRenewalUntilAcknowledged() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("part-1")
    try Data("immutable first part".utf8).write(to: file)
    let fingerprint = try UploadFileFingerprint.read(file)
    let transferID = "tenant-a/object-a/upload-a/part-1"
    let key = UploadTaskIdentity.key(transferID)
    let receipts = directory.appendingPathComponent("receipts")
    let first = BackgroundUploadSession(identifier: "test.\(UUID())", receiptDirectory: receipts)
    let url = try XCTUnwrap(URL(string: "https://example.test/upload?token=old&partNumber=1&uploadId=a"))
    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "part-etag"]))
    let body = Data(#"{"partNumber":1,"etag":"part-etag","receipt":"signed-receipt"}"#.utf8)
    await first.completed(description: UploadTaskIdentity.description(key: key, fingerprint: fingerprint),
      data: body, response: response, error: nil)
    let relaunched = BackgroundUploadSession(identifier: "test.\(UUID())", receiptDirectory: receipts)
    let renewed = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/upload?token=new&partNumber=1&uploadId=a")))
    let recovered = try await relaunched.upload(renewed, fromFile: file, transferID: transferID)
    XCTAssertEqual(recovered.0, body)
    XCTAssertEqual(recovered.1.value(forHTTPHeaderField: "ETag"), "part-etag")
    XCTAssertNotNil(UploadReceiptStore(directory: receipts).read(key: key))
    await relaunched.acknowledge(transferID: transferID, file: file)
    XCTAssertNil(UploadReceiptStore(directory: receipts).read(key: key))
  }

  func test_receiptCannotBeUsedForDifferentFileContent() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("part")
    try Data("original".utf8).write(to: file)
    let fingerprint = try UploadFileFingerprint.read(file)
    let session = BackgroundUploadSession(identifier: "test.\(UUID())", receiptDirectory: directory)
    let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/upload")))
    let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
    await session.completed(description: UploadTaskIdentity.description(key: UploadTaskIdentity.key("same"), fingerprint: fingerprint),
      data: Data(), response: response, error: nil)
    try Data("different".utf8).write(to: file)
    do {
      _ = try await session.upload(request, fromFile: file, transferID: "same")
      XCTFail("A transfer ID must never return another file's receipt")
    } catch UploadTransportError.transferIdentityConflict {} catch { XCTFail("Unexpected error: \(error)") }
  }

  func test_stagedFileSurvivesCallerCleanupUntilTransportCompletion() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("caller-part")
    let bytes = Data("complete part".utf8)
    try bytes.write(to: file)
    let store = UploadReceiptStore(directory: directory.appendingPathComponent("owned"))
    let fingerprint = try UploadFileFingerprint.read(file)
    let key = UploadTaskIdentity.key("tenant/upload/part")
    let staged = try store.stage(source: file, key: key, fingerprint: fingerprint)
    try FileManager.default.removeItem(at: file)
    XCTAssertEqual(try Data(contentsOf: staged), bytes)
    // A cancelled waiter does not own the staged file's lifetime. Completion does.
    let session = BackgroundUploadSession(identifier: "test.\(UUID())", receiptDirectory: store.directory)
    await session.completed(description: UploadTaskIdentity.description(key: key, fingerprint: fingerprint),
      data: Data(), response: nil, error: URLError(.cancelled))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
  }

  func test_expiredCorruptAndOversizedReceiptsAreNotAccepted() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UploadReceiptStore(directory: directory)
    let fingerprint = UploadFileFingerprint(bytes: 1, digest: String(repeating: "a", count: 64))
    let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: nil))
    let now = Date(timeIntervalSince1970: 1000)
    try store.write(key: "expired", fingerprint: fingerprint, data: Data(), response: response, now: now)
    XCTAssertNil(store.read(key: "expired", now: now.addingTimeInterval(UploadReceiptStore.maximumAge + 1)))
    try Data("broken".utf8).write(to: directory.appendingPathComponent("corrupt.json"))
    XCTAssertNil(store.read(key: "corrupt"))
    XCTAssertThrowsError(try store.write(key: "large", fingerprint: fingerprint,
      data: Data(repeating: 0, count: UploadReceiptStore.maximumBodyBytes + 1), response: response))
    XCTAssertNil(store.read(key: "large"))
  }

  func test_identityRetainsTenantUploadAndPartDistinctionsWithoutReadableSecrets() {
    let first = UploadTaskIdentity.key("tenant-a/object/upload-1/part-1")
    XCTAssertNotEqual(first, UploadTaskIdentity.key("tenant-b/object/upload-1/part-1"))
    XCTAssertNotEqual(first, UploadTaskIdentity.key("tenant-a/object/upload-2/part-1"))
    XCTAssertNotEqual(first, UploadTaskIdentity.key("tenant-a/object/upload-1/part-2"))
    let fingerprint = UploadFileFingerprint(bytes: 4, digest: String(repeating: "b", count: 64))
    let description = UploadTaskIdentity.description(key: first, fingerprint: fingerprint)
    XCTAssertFalse(description.contains("tenant-a"))
    XCTAssertEqual(UploadTaskIdentity.parse(description)?.key, first)
    XCTAssertEqual(UploadTaskIdentity.parse(description)?.fingerprint, fingerprint)
    XCTAssertNil(UploadTaskIdentity.parse("unrelated-task"))
  }

  @MainActor
  func test_lateHostRegistrationCompletesExactlyOnceAfterDrainedEvents() {
    var events = UploadBackgroundEventState()
    var calls = 0
    XCTAssertTrue(events.finish().isEmpty)
    for completion in events.register({ calls += 1 }) { completion() }
    XCTAssertEqual(calls, 1)
    for completion in events.finish() { completion() }
    XCTAssertEqual(calls, 1)
    events.workStarted()
    XCTAssertTrue(events.register({ calls += 1 }).isEmpty)
    XCTAssertEqual(calls, 1)
    for completion in events.finish() { completion() }
    XCTAssertEqual(calls, 2)
    XCTAssertTrue(events.finish().isEmpty)
  }

  func test_completedReceiptTasksDoNotAccumulateWithoutBackgroundEvents() async {
    let tasks = UploadCompletionTasks()
    for _ in 0..<200 { tasks.enqueue {} }
    await tasks.drain()
    XCTAssertEqual(tasks.activeCount, 0)
  }

  func test_drainWaitsForActiveReceiptWrites() async {
    let tasks = UploadCompletionTasks()
    let gate = ReceiptWriteGate()
    tasks.enqueue { await gate.wait() }
    XCTAssertEqual(tasks.activeCount, 1)
    let drain = Task { await tasks.drain() }
    await gate.release()
    await drain.value
    XCTAssertEqual(tasks.activeCount, 0)
  }

  func test_receiptWriteFailureRemovesOnlyTerminalStagedCopy() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("original")
    let data = Data("retained original".utf8)
    try data.write(to: source)
    let fingerprint = try UploadFileFingerprint.read(source)
    let key = UploadTaskIdentity.key("part")
    let store = UploadReceiptStore(directory: directory.appendingPathComponent("receipts"))
    let staged = try store.stage(source: source, key: key, fingerprint: fingerprint)
    // A directory at the receipt path makes the atomic receipt write fail.
    try FileManager.default.createDirectory(at: store.directory.appendingPathComponent(key + ".json"), withIntermediateDirectories: true)
    let session = BackgroundUploadSession(identifier: "test.\(UUID())", receiptDirectory: store.directory)
    let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: nil))
    await session.completed(description: UploadTaskIdentity.description(key: key, fingerprint: fingerprint),
      data: Data(), response: response, error: nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    XCTAssertEqual(try Data(contentsOf: source), data)
  }

  func test_unknownHostSessionIsNotConsumed() {
    let session = BackgroundUploadSession(identifier: "known", receiptDirectory: FileManager.default.temporaryDirectory)
    XCTAssertFalse(session.handleEvents(forBackgroundURLSession: "other", completionHandler: {}))
  }
}

private actor ReceiptWriteGate {
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
