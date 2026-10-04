import Foundation

enum FeedbackHubOperationContext {
  @TaskLocal static var generation: UUID?
}

actor FeedbackHubClient {
  private struct IdentityState: Codable {
    let generation: UUID
    var identity: FeedbackReporterIdentity?
  }
  private struct CachedPage: Codable {
    let reporterId: String
    let storedAt: Date
    let page: FeedbackIdeaPage
  }
  let config: ShakeToShipConfig
  let storage: FeedbackHubStorage
  private let transport: any FeedbackTransport
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private var replayTask: Task<Void, Never>?
  private var renewalRetryAt = Date.distantPast
  private var state: IdentityState
  private nonisolated let accessGate = FeedbackHubAccessGate()
  private var active = false
  private var blocked = false
  private var epoch = UUID()
  private var requests: [UUID: Task<(Data, HTTPURLResponse), Error>] = [:]
  private var exchange: Task<FeedbackReporterIdentity, Error>?
  private var queue: FeedbackOpsQueue?
  private var replayEpoch: UUID?
  private var resetHandler: (@MainActor @Sendable () -> Void)?
  private var visibilityGeneration = UUID()

  init(
    config: ShakeToShipConfig, storage: FeedbackHubStorage,
    transport: any FeedbackTransport = URLSessionTransport.hub(),
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
      try await Task.sleep(for: .seconds($0))
    }
  ) throws {
    self.config = config
    self.storage = storage
    self.transport = transport
    self.now = now
    self.sleep = sleep
    if let data = try storage.readIdentity() {
      state = try JSONDecoder().decode(IdentityState.self, from: data)
    } else {
      state = IdentityState(generation: UUID())
      try storage.clearPrivateData()
      try storage.writeIdentity(JSONEncoder().encode(state))
    }
    accessGate.setGeneration(state.generation)
  }
  nonisolated var localGeneration: UUID { accessGate.generation }
  var generation: UUID { state.generation }
  func setActive(_ value: Bool) {
    active = FeedbackGate.shouldAttachHub(config: config, recorderActive: value)
    accessGate.set(active)
    if !active { cancel() }
  }
  nonisolated func disableImmediately() {
    accessGate.set(false)
    Task { await self.setActive(false) }
  }
  private func cancel() {
    epoch = UUID()
    replayEpoch = nil
    replayTask?.cancel()
    replayTask = nil
    requests.values.forEach { $0.cancel() }
    requests.removeAll()
    exchange?.cancel()
    exchange = nil
  }
  private func check(_ expected: UUID? = nil) throws {
    guard active, accessGate.isOpen, !blocked else { throw FeedbackHubError.inactive }
    if let generation = FeedbackHubOperationContext.generation, generation != state.generation {
      throw FeedbackHubError.identityChanged
    }
    if let expected, expected != epoch { throw FeedbackHubError.identityChanged }
    try Task.checkCancellation()
  }
  func observeReset(_ handler: @escaping @MainActor @Sendable () -> Void) { resetHandler = handler }
  func reset() async throws {
    cancel()
    queue = nil
    state = IdentityState(generation: UUID())
    accessGate.setGeneration(state.generation)
    // Failure leaves this process disabled. Never restore a prior bearer or queue.
    blocked = true
    await resetHandler?()
    try storage.writeIdentity(nil)
    try storage.clearPrivateData()
    try storage.writeIdentity(JSONEncoder().encode(state))
    blocked = false
  }
  func identity() async throws -> FeedbackReporterIdentity {
    try check()
    if let identity = state.identity, let expiry = identity.expiresAt,
      expiry > now() && (expiry.timeIntervalSince(now()) > 7 * 86400 || renewalRetryAt > now())
    {
      return identity
    }
    if let exchange {
      let expected = epoch
      do {
        let result = try await exchange.value
        try check(expected)
        return result
      } catch {
        return try recoverRenewal(error, original: state.identity, expected: expected)
      }
    }
    let expected = epoch
    let old = state.identity
    let task = Task { try await self.performExchange(old: old, epoch: expected) }
    exchange = task
    do {
      let value = try await task.value
      try check(expected)
      state.identity = value
      try storage.writeIdentity(JSONEncoder().encode(state))
      exchange = nil
      return value
    } catch {
      if expected == epoch { exchange = nil }
      return try recoverRenewal(error, original: old, expected: expected)
    }
  }
  private func recoverRenewal(_ error: Error, original: FeedbackReporterIdentity?, expected: UUID)
    throws -> FeedbackReporterIdentity
  {
    try check(expected)
    let transient: Bool
    if case FeedbackHubError.http(let status, _, _) = error {
      transient = status == 429 || status >= 500
    } else {
      transient = error is URLError
    }
    if transient, let original, let expiry = original.expiresAt, expiry > now() {
      renewalRetryAt = now().addingTimeInterval(60)
      return original
    }
    throw error
  }
  private func performExchange(old: FeedbackReporterIdentity?, epoch: UUID) async throws
    -> FeedbackReporterIdentity
  {
    var fields: [String: FeedbackHubValue] = [:]
    if let label = config.userRef { fields["hostUserRef"] = .string(label) }
    if case .email(let email) = config.contact { fields["contact"] = .string(email) }
    var request = try makeRequest("identity", method: "POST", fields: fields, reporter: old)
    if let traits = config.traits {
      var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
      body["traits"] = traits
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let data = try await send(request, epoch: epoch)
    let result = try JSONDecoder().decode(FeedbackReporterIdentity.self, from: data)
    guard !result.reporterId.isEmpty, result.expiresAt != nil,
      old == nil || old?.reporterId == result.reporterId
    else { throw FeedbackHubError.invalidResponse }
    return result
  }
  private func makeRequest(
    _ path: String, method: String, fields: [String: FeedbackHubValue],
    reporter: FeedbackReporterIdentity?, query: [URLQueryItem] = []
  ) throws -> URLRequest {
    var components = URLComponents(
      url: config.collectorURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.isEmpty ? nil : query
    if method == "GET" {
      components.queryItems = query + [URLQueryItem(name: "app", value: config.app)]
    }
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 30
    request.httpMethod = method
    request.setValue(config.secret, forHTTPHeaderField: "x-feedback-secret")
    request.setValue(reporter?.reporterToken, forHTTPHeaderField: "x-reporter-token")
    if method != "GET" {
      var body = fields
      body["app"] = .string(config.app)
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }
  private func send(_ request: URLRequest, epoch expected: UUID) async throws -> Data {
    try check(expected)
    let id = UUID()
    let task = Task { try await transport.perform(request) }
    requests[id] = task
    defer { requests.removeValue(forKey: id) }
    let result: (Data, HTTPURLResponse)
    do { result = try await task.value } catch {
      try check(expected)
      throw error
    }
    let (data, response) = result
    try check(expected)
    if response.statusCode == 401 || response.statusCode == 403 {
      try await reset()
      throw FeedbackHubError.authentication
    }
    guard (200..<300).contains(response.statusCode) else {
      throw FeedbackHubError.http(
        response.statusCode, String(decoding: data, as: UTF8.self),
        response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
    }
    return data
  }
  func request(
    _ path: String, method: String = "GET", fields: [String: FeedbackHubValue] = [:],
    query: [URLQueryItem] = []
  ) async throws -> Data {
    try check()
    if path.hasPrefix("ideas"), !config.hub.contains(.ideas) { throw FeedbackHubError.inactive }
    if path.hasPrefix("prompts"), !config.hub.contains(.prompts) { throw FeedbackHubError.inactive }
    if path.hasPrefix("v2/inbox"), !config.hub.contains(.inbox) { throw FeedbackHubError.inactive }
    if path.hasPrefix("v2/reports"), !config.hub.contains(.inbox) { throw FeedbackHubError.inactive }
    let expected = epoch
    let reporter = try await identity()
    try check(expected)
    let visibility = visibilityGeneration
    let data = try await send(
      makeRequest(path, method: method, fields: fields, reporter: reporter, query: query),
      epoch: expected)
    if path.hasPrefix("ideas"), visibility != visibilityGeneration {
      throw FeedbackHubError.visibilityChanged
    }
    if method == "POST", path.hasSuffix("/report") || path.hasSuffix("/block-author") {
      try invalidateVisibility()
    }
    return data
  }
  func decode<T: Decodable & Sendable>(
    _ type: T.Type, path: String, method: String = "GET",
    fields: [String: FeedbackHubValue] = [:], query: [URLQueryItem] = []
  ) async throws -> T {
    try await JSONDecoder().decode(
      type, from: request(path, method: method, fields: fields, query: query))
  }
  func ideas(filter: String, cursor: String? = nil) async throws -> FeedbackIdeaPage {
    var query = [URLQueryItem(name: "filter", value: filter)]
    if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
    let expected = epoch
    let reporter = try await identity()
    let file = "ideas-\(filter).json"
    let visibility = visibilityGeneration
    do {
      let page = try await decode(FeedbackIdeaPage.self, path: "ideas", query: query)
      try check(expected)
      guard visibility == visibilityGeneration else { throw FeedbackHubError.visibilityChanged }
      if cursor == nil {
        try storage.write(
          CachedPage(reporterId: reporter.reporterId, storedAt: now(), page: page), file: file)
      }
      return page
    } catch {
      try check(expected)
      guard visibility == visibilityGeneration else { throw FeedbackHubError.visibilityChanged }
      // Only transport failures may use cached data. HTTP visibility/auth failures must not show stale content.
      if error is URLError, cursor == nil,
        let cached = try storage.read(CachedPage.self, file: file),
        cached.reporterId == reporter.reporterId,
        (0...300).contains(now().timeIntervalSince(cached.storedAt))
      {
        return cached.page
      }
      throw error
    }
  }
  func enqueue(_ op: FeedbackOpsQueue.Operation, target: String, value: FeedbackHubValue)
    async throws
  {
    let expected = epoch
    let reporter = try await identity()
    try check(expected)
    if queue == nil {
      queue = try FeedbackOpsQueue(
        url: storage.root.appendingPathComponent("ops.json"), reporterId: reporter.reporterId)
    }
    try queue?.enqueue(op: op, targetId: target, desiredState: value, now: now())
  }
  func replay() async throws {
    try check()
    guard replayEpoch == nil else { return }
    let expected = epoch
    replayEpoch = expected
    defer {
      if replayEpoch == expected {
        replayEpoch = nil
        scheduleReplay()
      }
    }
    let reporter = try await identity()
    try check(expected)
    if queue == nil {
      queue = try FeedbackOpsQueue(
        url: storage.root.appendingPathComponent("ops.json"), reporterId: reporter.reporterId)
    }
    try queue?.prune(now: now())
    for _ in 0..<5 {
      try check(expected)
      guard
        let item = queue?.operations.first(where: {
          $0.op == .vote ? config.hub.contains(.ideas) : config.hub.contains(.prompts)
        })
      else { return }
      guard item.reporterId == reporter.reporterId, item.nextAttemptAt <= now() else { return }
      let path: String
      let method: String
      let fields: [String: FeedbackHubValue]
      switch item.op {
      case .vote:
        path = "ideas/\(item.targetId)/vote"
        method = "PUT"
        fields = ["voted": item.desiredState, "seq": .integer(Int(item.seq))]
      case .promptAnswer:
        path = "prompts/\(item.targetId)/answer"
        method = "POST"
        fields = ["value": item.desiredState]
      case .promptDismiss:
        path = "prompts/\(item.targetId)/dismiss"
        method = "POST"
        fields = ["impressionId": item.desiredState]
      }
      do {
        _ = try await request(path, method: method, fields: fields)
        try check(expected)
        try queue?.remove(seq: item.seq)
      } catch let error as FeedbackHubError {
        try check(expected)
        if case .http(let status, _, let retryAfter) = error {
          if [400, 404, 409, 410, 413, 415, 422].contains(status) {
            try queue?.remove(seq: item.seq)
            continue
          }
          try queue?.postpone(item, now: now(), retryAfter: retryAfter)
          return
        }
        throw error
      } catch {
        try check(expected)
        try queue?.postpone(item, now: now(), retryAfter: nil)
        return
      }
    }
  }
  private func scheduleReplay() {
    replayTask?.cancel()
    replayTask = nil
    guard active, !blocked,
      let item = queue?.operations.first(where: {
        $0.op == .vote ? config.hub.contains(.ideas) : config.hub.contains(.prompts)
      }), item.attempts < 5
    else { return }
    let delay = max(0.1, item.nextAttemptAt.timeIntervalSince(now()))
    let expected = epoch
    replayTask = Task { [weak self, sleep] in
      do {
        try await sleep(delay)
        guard let self else { return }
        try await self.resumeReplay(expected)
      } catch { /* A disabled gate or bounded retry ends this scheduled attempt. */  }
    }
  }
  private func resumeReplay(_ expected: UUID) async throws {
    try check(expected)
    replayTask = nil
    try await replay()
  }
  func nextPrompt() async throws -> Data {
    try check()
    guard config.hub.contains(.prompts) else { throw FeedbackHubError.inactive }
    let expected = epoch
    let reporter = try await identity()
    try check(expected)
    if queue == nil {
      queue = try FeedbackOpsQueue(
        url: storage.root.appendingPathComponent("ops.json"), reporterId: reporter.reporterId)
    }
    try queue?.prune(now: now())
    // A queued answer/dismissal already has an impression. Do not reserve another while it is pending.
    if queue?.operations.contains(where: { $0.op != .vote }) == true { return Data() }
    return try await request("prompts/next")
  }
  func pendingVotes() -> [FeedbackOpsQueue.Item] {
    queue?.operations.filter { $0.op == .vote } ?? []
  }
  func acknowledge(_ ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    let expected = epoch
    let reporter = try await identity()
    var request = try makeRequest("v2/inbox/ack", method: "POST", fields: [:], reporter: reporter)
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "app": config.app, "messageIds": Array(ids.prefix(100)),
    ])
    _ = try await send(request, epoch: expected)
  }
  func bindCapture(in directory: URL, purpose: FeedbackCapturePurpose = .report) throws {
    try check()
    let binding = FeedbackCaptureBinding(
      scope: storage.scope, generation: state.generation, purpose: purpose)
    try JSONEncoder().encode(binding).write(
      to: directory.appendingPathComponent(FeedbackCaptureBinding.filename), options: .atomic)
  }
  func captureIdentity(_ binding: FeedbackCaptureBinding) async throws -> FeedbackReporterIdentity {
    try check()
    guard binding.scope == storage.scope, binding.generation == state.generation else {
      throw FeedbackHubError.identityChanged
    }
    let expected = epoch
    let reporter = try await identity()
    try check(expected)
    return reporter
  }
  func invalidateVisibility() throws {
    visibilityGeneration = UUID()
    for filter in ["top", "new", "planned", "shipped", "mine"] {
      let file = storage.root.appendingPathComponent("ideas-\(filter).json")
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
    }
  }
  func ownsCapture(_ binding: FeedbackCaptureBinding) -> Bool {
    active && accessGate.isOpen && !blocked && binding.scope == storage.scope
      && binding.generation == state.generation
  }
  func captureTransfer(_ request: URLRequest, file: URL?, binding: FeedbackCaptureBinding)
    async throws -> (Data, HTTPURLResponse)
  {
    try check()
    guard ownsCapture(binding) else { throw FeedbackHubError.identityChanged }
    let expected = epoch
    let id = UUID()
    // Reporter-bound transfers always use the cancellable hub transport. They never enter the
    // legacy background session, whose detached OS transfers intentionally survive task cancellation.
    let task = Task {
      if let file { return try await transport.upload(request, fromFile: file) }
      return try await transport.perform(request)
    }
    requests[id] = task
    defer { requests.removeValue(forKey: id) }
    let result: (Data, HTTPURLResponse)
    do { result = try await task.value } catch {
      try check(expected)
      throw error
    }
    try check(expected)
    return result
  }
  func capturePresign(_ request: URLRequest, binding: FeedbackCaptureBinding) async throws -> Data {
    _ = try await captureIdentity(binding)
    let expected = epoch
    return try await send(request, epoch: expected)
  }
  func saveSessionRecord(
    _ id: String, captureId: String, binding: FeedbackCaptureBinding,
    reporter: FeedbackReporterIdentity
  ) throws {
    try check()
    guard binding.scope == storage.scope, binding.generation == state.generation,
      reporter.reporterId == state.identity?.reporterId
    else { throw FeedbackHubError.identityChanged }
    var sessions = try ownedSessions()
    sessions.removeAll { $0.captureId == captureId }
    sessions.append(
      FeedbackOwnedSession(
        id: id, captureId: captureId, purpose: binding.purpose, reporterId: reporter.reporterId,
        generation: state.generation, createdAt: now()))
    try storage.write(Array(sessions.suffix(50)), file: "sessions.json")
  }
  func attachExistingReport(_ sessionID: String, to ideaID: String) async throws {
    try check()
    guard try attachableReports().contains(where: { $0.id == sessionID }) else {
      throw FeedbackHubError.identityChanged
    }
    _ = try await request(
      "ideas/\(ideaID)/details", method: "POST", fields: ["sessionId": .string(sessionID)])
  }
  func attachableReports() throws -> [FeedbackOwnedSession] {
    try ownedSessions().filter { $0.purpose == .report }
  }
  func ownedSessions() throws -> [FeedbackOwnedSession] {
    try check()
    return (try storage.read([FeedbackOwnedSession].self, file: "sessions.json") ?? []).filter {
      $0.generation == state.generation && $0.reporterId == state.identity?.reporterId
    }
  }

  func reportDetail(_ id: String) async throws -> FeedbackOwnedReportDetail {
    try check()
    guard config.hub.contains(.inbox), FeedbackOwnedReportDetail.validID(id),
      try ownedSessions().contains(where: { $0.id == id && $0.purpose == .report })
    else { throw FeedbackHubError.identityChanged }
    let detail = try await decode(FeedbackOwnedReportDetail.self, path: "v2/reports/\(id)")
    guard detail.id == id else { throw FeedbackHubError.invalidResponse }
    return detail
  }

  /// Returns only a local file URL. The reporter token stays on the authenticated request.
  func reportMedia(
    for detail: FeedbackOwnedReportDetail, attachment: FeedbackOwnedReportAttachment
  ) async throws -> URL {
    try check()
    guard config.hub.contains(.inbox), FeedbackOwnedReportDetail.validID(detail.id),
      detail.attachments.contains(attachment),
      try ownedSessions().contains(where: { $0.id == detail.id && $0.purpose == .report })
    else { throw FeedbackHubError.identityChanged }
    let expected = epoch
    let folder = storage.root.appendingPathComponent("report-media", isDirectory: true)
      .appendingPathComponent(detail.id, isDirectory: true)
    let file = folder.appendingPathComponent(attachment.file)
    if FileManager.default.fileExists(atPath: file.path) {
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      if size > 0 { return file }
    }
    let bytes = try await request("v2/reports/\(detail.id)/media/\(attachment.file)")
    try check(expected)
    guard !bytes.isEmpty else { throw FeedbackHubError.invalidResponse }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var excludedFolder = folder
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excludedFolder.setResourceValues(values)
    try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return file
  }
}

/// The SwiftUI removal callback closes this gate synchronously, before the actor's cancellation turn.
private final class FeedbackHubAccessGate: @unchecked Sendable {
  private let lock = NSLock()
  private var open = false
  private var identityGeneration = UUID()
  var generation: UUID { lock.withLock { identityGeneration } }
  func setGeneration(_ value: UUID) { lock.withLock { identityGeneration = value } }
  var isOpen: Bool { lock.withLock { open } }
  func set(_ value: Bool) { lock.withLock { open = value } }
}
