import CryptoKit
import Foundation
import os

struct UploadFileFingerprint: Codable, Sendable, Equatable {
  let bytes: Int
  let digest: String

  static func read(_ file: URL) throws -> Self {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hash = SHA256()
    var count = 0
    while let data = try handle.read(upToCount: 262_144), !data.isEmpty {
      count += data.count
      hash.update(data: data)
    }
    return Self(bytes: count, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
}

enum UploadTaskIdentity {
  static let prefix = "app-uploads-v1:"
  static func key(_ transferID: String) -> String {
    SHA256.hash(data: Data(transferID.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func description(key: String, fingerprint: UploadFileFingerprint) -> String {
    "\(prefix)\(key):\(fingerprint.digest):\(fingerprint.bytes)"
  }
  static func parse(_ description: String?) -> (key: String, fingerprint: UploadFileFingerprint)? {
    guard let description, description.hasPrefix(prefix) else { return nil }
    let parts = description.dropFirst(prefix.count).split(separator: ":")
    guard parts.count == 3, parts[0].count == 64, parts[1].count == 64,
      parts[0].allSatisfy(\.isHexDigit), parts[1].allSatisfy(\.isHexDigit),
      let count = Int(parts[2]), count >= 0 else { return nil }
    return (String(parts[0]), UploadFileFingerprint(bytes: count, digest: String(parts[1])))
  }
}

struct UploadReceiptStore: Sendable {
  struct Receipt: Codable, Sendable {
    let fingerprint: UploadFileFingerprint
    let savedAt: Date
    let status: Int
    let headers: [String: String]
    let data: Data
  }
  let directory: URL
  static let maximumBodyBytes = 65_536
  static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

  func read(key: String, now: Date = Date()) -> Receipt? {
    let url = directory.appendingPathComponent(key + ".json")
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 131_072,
      let bytes = try? Data(contentsOf: url),
      let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes),
      now.timeIntervalSince(receipt.savedAt) >= 0,
      now.timeIntervalSince(receipt.savedAt) < Self.maximumAge else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return receipt
  }

  func write(key: String, fingerprint: UploadFileFingerprint, data: Data,
             response: HTTPURLResponse, now: Date = Date()) throws {
    guard data.count <= Self.maximumBodyBytes else { throw UploadTransportError.responseTooLarge }
    guard (200..<300).contains(response.statusCode) else { return }
    let headers = ["ETag", "Content-Type"].reduce(into: [String: String]()) { result, field in
      if let value = response.value(forHTTPHeaderField: field) { result[field] = value }
    }
    let receipt = Receipt(fingerprint: fingerprint, savedAt: now, status: response.statusCode,
      headers: headers, data: data)
    try prepareDirectory(directory)
    let file = directory.appendingPathComponent(key + ".json")
    let data = try JSONEncoder().encode(receipt)
    #if os(iOS)
    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
    try data.write(to: file, options: .atomic)
    #endif
  }

  func acknowledge(key: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".json")) }

  func stagedFile(key: String) -> URL {
    directory.appendingPathComponent("staged", isDirectory: true).appendingPathComponent(key + ".upload")
  }

  func stage(source: URL, key: String, fingerprint: UploadFileFingerprint) throws -> URL {
    let target = stagedFile(key: key)
    if let existing = try? UploadFileFingerprint.read(target), existing == fingerprint { return target }
    let folder = target.deletingLastPathComponent()
    try prepareDirectory(folder)
    let temporary = folder.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.copyItem(at: source, to: temporary)
    guard try UploadFileFingerprint.read(temporary) == fingerprint else { throw UploadTransportError.transferIdentityConflict }
    #if os(iOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
    #endif
    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    try FileManager.default.moveItem(at: temporary, to: target)
    return target
  }

  func removeStaged(key: String) { try? FileManager.default.removeItem(at: stagedFile(key: key)) }

  private func prepareDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var folder = url
    try folder.setResourceValues(excluded)
  }
}

/// Keeps the host callback safe when UIKit registers it after delegate drain.
struct UploadBackgroundEventState {
  private var drained = false
  private var handlers: [@MainActor () -> Void] = []

  mutating func workStarted() { drained = false }
  mutating func register(_ handler: @escaping @MainActor () -> Void) -> [@MainActor () -> Void] {
    if drained { return [handler] }
    handlers.append(handler)
    return []
  }
  mutating func finish() -> [@MainActor () -> Void] {
    drained = true
    let result = handlers
    handlers.removeAll()
    return result
  }
}

/// File tasks continue under system scheduling after suspension. A user force-quit
/// does not promise continuation. Keep the same identifier and directory on relaunch.
public actor BackgroundUploadSession: UploadTransport {
  public nonisolated let supportsBackgroundUploads = true
  public nonisolated let identifier: String
  private let foreground: URLSession
  private let receipts: UploadReceiptStore
  private let onEventsDrained: (@Sendable () async -> Void)?
  private var session: URLSession?
  private struct Pending {
    let fingerprint: UploadFileFingerprint
    var waiters: [UUID: CheckedContinuation<(Data, HTTPURLResponse), Error>]
  }
  private var pending: [String: Pending] = [:]
  private var backgroundEvents = UploadBackgroundEventState()

  public init(identifier: String, receiptDirectory: URL, foreground: URLSession = .shared,
              onEventsDrained: (@Sendable () async -> Void)? = nil) {
    self.identifier = identifier
    self.receipts = UploadReceiptStore(directory: receiptDirectory)
    self.foreground = foreground
    self.onEventsDrained = onEventsDrained
  }

  public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await foreground.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw UploadTransportError.notHTTP }
    return (data, response)
  }

  /// Detaches a cancelled caller without cancelling the system task. The system
  /// uploads a package-owned copy, so caller cleanup cannot remove its source.
  public func upload(_ request: URLRequest, fromFile file: URL, transferID: String) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    let key = UploadTaskIdentity.key(transferID)
    let fingerprint = try await Task.detached(priority: .utility) { try UploadFileFingerprint.read(file) }.value
    try Task.checkCancellation()
    if let restored = try restoredResponse(key: key, fingerprint: fingerprint, request: request) { return restored }
    if let existing = pending[key], existing.fingerprint != fingerprint { throw UploadTransportError.transferIdentityConflict }
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let isNew = pending[key] == nil
        if isNew { pending[key] = Pending(fingerprint: fingerprint, waiters: [:]) }
        pending[key]?.waiters[waiterID] = continuation
        if isNew { Task { await self.startOrAttach(request, file: file, key: key, fingerprint: fingerprint) } }
      }
    } onCancel: {
      Task { await self.cancelWaiter(key: key, id: waiterID) }
    }
  }

  public func acknowledge(transferID: String, file: URL) async {
    receipts.acknowledge(key: UploadTaskIdentity.key(transferID))
  }

  /// Forward the host's background-session event callback to this exact instance.
  /// The resume hook is scheduled after durable receipts drain. Host completion
  /// does not wait for new network operations started by that hook.
  @discardableResult
  public nonisolated func handleEvents(forBackgroundURLSession identifier: String,
      completionHandler: @escaping @MainActor () -> Void) -> Bool {
    guard identifier == self.identifier else { return false }
    Task { await self.registerCompletion(completionHandler) }
    return true
  }

  public func reconnect() { _ = activeSession() }

  private func registerCompletion(_ completion: @escaping @MainActor () -> Void) async {
    let ready = backgroundEvents.register(completion)
    _ = activeSession()
    for handler in ready { await handler() }
  }

  private func activeSession() -> URLSession {
    if let session { return session }
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.waitsForConnectivity = true
    configuration.httpMaximumConnectionsPerHost = 2
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let created = URLSession(configuration: configuration,
      delegate: BackgroundUploadDelegate(coordinator: self), delegateQueue: queue)
    session = created
    return created
  }

  private func restoredResponse(key: String, fingerprint: UploadFileFingerprint,
      request: URLRequest) throws -> (Data, HTTPURLResponse)? {
    guard let receipt = receipts.read(key: key) else { return nil }
    guard receipt.fingerprint == fingerprint else { throw UploadTransportError.transferIdentityConflict }
    guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: receipt.status,
      httpVersion: "HTTP/1.1", headerFields: receipt.headers) else { throw UploadTransportError.notHTTP }
    return (receipt.data, response)
  }

  private func startOrAttach(_ request: URLRequest, file: URL, key: String, fingerprint: UploadFileFingerprint) async {
    do {
      let session = activeSession()
      let tasks = await session.allTasks
      if let restored = try restoredResponse(key: key, fingerprint: fingerprint, request: request) {
        finishWaiters(key: key, result: .success(restored)); return
      }
      guard pending[key] != nil else { return }
      if let task = tasks.first(where: { UploadTaskIdentity.parse($0.taskDescription)?.key == key && $0.state != .completed }) {
        guard UploadTaskIdentity.parse(task.taskDescription)?.fingerprint == fingerprint else { throw UploadTransportError.transferIdentityConflict }
        if task.state == .suspended { task.resume() }
        return
      }
      let receipts = self.receipts
      let staged = try await Task.detached(priority: .utility) { try receipts.stage(source: file, key: key, fingerprint: fingerprint) }.value
      guard pending[key] != nil else { receipts.removeStaged(key: key); return }
      backgroundEvents.workStarted()
      let task = session.uploadTask(with: request, fromFile: staged)
      task.taskDescription = UploadTaskIdentity.description(key: key, fingerprint: fingerprint)
      task.resume()
    } catch { finishWaiters(key: key, result: .failure(error)) }
  }

  private func cancelWaiter(key: String, id: UUID) {
    pending[key]?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    // Keep the pending entry until reconciliation finishes. A replacement caller
    // must not start a second reconciliation while staging is suspended.
  }

  private func finishWaiters(key: String, result: Result<(Data, HTTPURLResponse), Error>) {
    guard let entry = pending.removeValue(forKey: key) else { return }
    for waiter in entry.waiters.values { waiter.resume(with: result) }
  }

  func completed(description: String?, data: Data, response: HTTPURLResponse?, error: Error?) {
    guard let identity = UploadTaskIdentity.parse(description) else { return }
    backgroundEvents.workStarted()
    // The OS task is terminal. The caller retains the original and can stage it
    // again if receipt persistence fails; no completed task needs this copy.
    defer { receipts.removeStaged(key: identity.key) }
    if let error {
      finishWaiters(key: identity.key, result: .failure(error))
    } else if let response {
      do {
        try receipts.write(key: identity.key, fingerprint: identity.fingerprint, data: data, response: response)
        finishWaiters(key: identity.key, result: .success((data, response)))
      } catch { finishWaiters(key: identity.key, result: .failure(error)) }
    } else {
      finishWaiters(key: identity.key, result: .failure(UploadTransportError.notHTTP))
    }
  }

  func eventsDrained() async {
    if let onEventsDrained { Task { await onEventsDrained() } }
    let handlers = backgroundEvents.finish()
    for completion in handlers { await completion() }
  }
}

/// Tracks only receipt writes that are still active. Registration and task
/// creation share the lock, so a fast completion cannot precede registration.
final class UploadCompletionTasks: Sendable {
  private let tasks = OSAllocatedUnfairLock(initialState: [UUID: Task<Void, Never>]())

  var activeCount: Int { tasks.withLock { $0.count } }

  func enqueue(_ operation: @escaping @Sendable () async -> Void) {
    let id = UUID()
    tasks.withLock { pending in
      pending[id] = Task {
        await operation()
        _ = self.tasks.withLock { $0.removeValue(forKey: id) }
      }
    }
  }

  func drain() async {
    let pending = tasks.withLock { Array($0.values) }
    for task in pending { await task.value }
  }
}

private final class BackgroundUploadDelegate: NSObject, URLSessionDataDelegate, Sendable {
  private struct State {
    var bodies: [Int: Data] = [:]
    var oversized: Set<Int> = []
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let coordinator: BackgroundUploadSession
  private let completions = UploadCompletionTasks()
  init(coordinator: BackgroundUploadSession) { self.coordinator = coordinator }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let overflow = state.withLock { state in
      guard !state.oversized.contains(dataTask.taskIdentifier) else { return true }
      let count = state.bodies[dataTask.taskIdentifier]?.count ?? 0
      guard count + data.count <= UploadReceiptStore.maximumBodyBytes else {
        state.oversized.insert(dataTask.taskIdentifier); return true
      }
      state.bodies[dataTask.taskIdentifier, default: Data()].append(data)
      return false
    }
    if overflow { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let (data, overflow) = state.withLock {
      ($0.bodies.removeValue(forKey: task.taskIdentifier) ?? Data(),
       $0.oversized.remove(task.taskIdentifier) != nil)
    }
    let description = task.taskDescription
    let response = task.response as? HTTPURLResponse
    let failure: Error? = overflow ? UploadTransportError.responseTooLarge : error
    completions.enqueue { [coordinator] in
      await coordinator.completed(description: description, data: data, response: response, error: failure)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task {
      await completions.drain()
      await coordinator.eventsDrained()
    }
  }
}
