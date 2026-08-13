import Foundation

/// Injectable HTTP seam so presign/upload logic is unit testable without network.
public protocol FeedbackTransport: Sendable {
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
  /// Streams `file` from disk as the request body (no full-file `Data` copy) -
  /// used for the recording PUT so a ~100MB video upload never doubles memory.
  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse)
}

/// Production transport backed by `URLSession`.
public struct URLSessionTransport: FeedbackTransport {
  private let session: URLSession
  public init(session: URLSession = .shared) { self.session = session }

  public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw FeedbackUploadError.notHTTP
    }
    return (data, http)
  }

  public func upload(_ request: URLRequest, fromFile file: URL) async throws -> (
    Data, HTTPURLResponse
  ) {
    let (data, response) = try await session.upload(for: request, fromFile: file)
    guard let http = response as? HTTPURLResponse else {
      throw FeedbackUploadError.notHTTP
    }
    return (data, http)
  }
}

public enum FeedbackUploadError: Error {
  case notHTTP
  case missingPresignedURL(String)
}

/// The original capture files. Additional segments use
/// `recording-NNN.mov` and are discovered with a strict filename check.
let feedbackFileNames = ["recording.mov", "events.json"]

/// Local confirmation marker written into a session dir when the user taps
/// Upload in the review sheet. NEVER uploaded - kept out of `feedbackFileNames`
/// so it is never presigned/PUT - it only tells the launch sweep this session
/// was user-confirmed and may be flushed.
public let feedbackConfirmedMarker = ".confirmed"

/// Writes the user-confirmation marker into `dir`, retrying ONCE on failure.
/// Returns true only when the marker is on disk.
///
/// The caller must not treat a failed write as "queued": without the marker the
/// launch sweep will purge the session once stale, so a UI that promised a
/// retry would be lying. `write` is the injected non-deterministic leaf (real
/// `Data.write` by default) so the retry is testable.
@discardableResult
func writeFeedbackConfirmedMarker(
  in dir: URL,
  write: (URL) throws -> Void = { try Data().write(to: $0) }
) -> Bool {
  writeFeedbackMarker(feedbackConfirmedMarker, in: dir, write: write)
}

/// Marker written into a session dir when a recording is finalized after a
/// backgrounding interruption (#472). Like `.confirmed` it is NEVER uploaded
/// (not in `feedbackFileNames`), and it does NOT gate the launch sweep - it only
/// tags the finalized-but-unconfirmed partial so the next foreground can OFFER
/// to send it. An interrupted session the user never re-confirms is still purged
/// once stale, exactly like any other unconfirmed dir.
public let feedbackInterruptedMarker = ".interrupted"

/// Writes the interruption marker into `dir` (retries once). See
/// `writeFeedbackConfirmedMarker` for the retry rationale.
@discardableResult
func writeFeedbackInterruptedMarker(
  in dir: URL,
  write: (URL) throws -> Void = { try Data().write(to: $0) }
) -> Bool {
  writeFeedbackMarker(feedbackInterruptedMarker, in: dir, write: write)
}

/// Shared marker writer: creates `dir/<name>`, retrying ONCE on failure.
private func writeFeedbackMarker(
  _ name: String, in dir: URL, write: (URL) throws -> Void
) -> Bool {
  let url = dir.appendingPathComponent(name)
  for _ in 0..<2 {
    do {
      try write(url)
      return true
    } catch {
      continue
    }
  }
  return false
}

/// Persists a pause-durability sidecar: the segments closed so far plus the
/// `.interrupted` marker, written synchronously while backgrounding closes a
/// segment (#669). Without this, `pendingInterruptedSessions` cannot find a
/// paused session that never resumes because iOS killed the app while it was
/// backgrounded, so the partial silently vanishes once `retryOutbox` purges
/// the unconfirmed dir. `clearFeedbackPauseDurability` below undoes this on a
/// successful resume; the next pause simply overwrites `events.json` with the
/// latest segments. Never uploaded on its own - the marker only makes the
/// finalized partial DISCOVERABLE, exactly like the interruption path in
/// `stopRecording`.
@discardableResult
func writeFeedbackPauseDurability(in dir: URL, session: FeedbackSession) -> Bool {
  guard let data = try? JSONEncoder().encode(session) else { return false }
  do {
    try data.write(to: dir.appendingPathComponent("events.json"))
  } catch {
    return false
  }
  return writeFeedbackInterruptedMarker(in: dir)
}

/// Clears the pause-durability marker written above once a paused session
/// resumes - it is live again in-process, so it must not be offered by the
/// next foreground scan as an interrupted partial (#669).
func clearFeedbackPauseDurability(in dir: URL) {
  try? FileManager.default.removeItem(at: dir.appendingPathComponent(feedbackInterruptedMarker))
}

/// An interrupted-but-finalized session awaiting a foreground resend offer.
public struct FeedbackPendingInterrupted: Equatable, Sendable {
  public let sessionId: String
  public let dir: URL

  public init(sessionId: String, dir: URL) {
    self.sessionId = sessionId
    self.dir = dir
  }
}

/// Scans the outbox for sessions the interruption path finalized (#472): dirs
/// carrying the `.interrupted` marker AND a `recording.mov` (something to send)
/// but NOT yet `.confirmed`. The modifier reads this on `willEnterForeground` to
/// offer "your recording stopped when you left the app - send it?".
public func pendingInterruptedSessions(
  root: URL, fileManager: FileManager = .default
) -> [FeedbackPendingInterrupted] {
  guard
    let entries = try? fileManager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey])
  else { return [] }
  var pending: [FeedbackPendingInterrupted] = []
  for entry in entries {
    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    guard isDir else { continue }
    let interrupted = fileManager.fileExists(
      atPath: entry.appendingPathComponent(feedbackInterruptedMarker).path)
    let confirmed = fileManager.fileExists(
      atPath: entry.appendingPathComponent(feedbackConfirmedMarker).path)
    let hasRecording = fileManager.fileExists(
      atPath: entry.appendingPathComponent("recording.mov").path)
    guard interrupted, hasRecording, !confirmed else { continue }
    pending.append(
      FeedbackPendingInterrupted(sessionId: entry.lastPathComponent, dir: entry))
  }
  return pending
}

/// Tally of one `retryOutbox()` sweep. `flushed` = dirs uploaded and removed;
/// `queued` = dirs with files that failed upload (retained for next launch);
/// `purged` = zero-whitelisted-file dirs (crashed sessions) deleted.
public struct OutboxSweepResult: Sendable, Equatable {
  public let flushed: Int
  public let queued: Int
  public let purged: Int

  public init(flushed: Int, queued: Int, purged: Int) {
    self.flushed = flushed
    self.queued = queued
    self.purged = purged
  }
}

/// Presigns and uploads a session's files to R2 via the collector worker, then
/// deletes the local session dir on full success. Failures leave files in the
/// outbox for `retryOutbox()` to sweep on the next launch.
public struct FeedbackUploader {
  private let config: ShakeToShipConfig
  private let transport: FeedbackTransport
  private let fileManager: FileManager
  /// Root of `Documents/feedback-outbox`; each session lives in `<root>/<sessionId>/`.
  private let outboxRoot: URL

  public init(
    config: ShakeToShipConfig,
    transport: FeedbackTransport,
    fileManager: FileManager,
    outboxRoot: URL
  ) {
    self.config = config
    self.transport = transport
    self.fileManager = fileManager
    self.outboxRoot = outboxRoot
  }

  private struct PresignRequestBody: Encodable {
    let app: String
    let sessionId: String
    let files: [String]
    let userRef: String?
  }

  private struct PresignResponse: Decodable {
    let urls: [String: String]
  }

  /// Uploads `<outboxRoot>/<sessionId>/`. Presigns and PUTs only the whitelisted
  /// files that actually exist on disk (a dir missing one file still uploads the
  /// other instead of retrying forever). Returns true only when every uploaded
  /// file reached R2 AND the local dir was successfully removed; false on any
  /// upload OR deletion failure (files retained is then the honest state).
  @discardableResult
  public func flush(sessionId: String) async -> Bool {
    let dir = outboxRoot.appendingPathComponent(sessionId, isDirectory: true)
    let present = existingFiles(in: dir)
    guard !present.isEmpty else { return false }
    do {
      let urls = try await presign(sessionId: sessionId, files: present)
      for name in present {
        guard let putURLString = urls[name], let putURL = URL(string: putURLString) else {
          throw FeedbackUploadError.missingPresignedURL(name)
        }
        var req = URLRequest(url: putURL)
        req.httpMethod = "PUT"
        let (_, resp) = try await transport.upload(
          req, fromFile: dir.appendingPathComponent(name))
        guard resp.statusCode == 200 else { return false }
      }
      try fileManager.removeItem(at: dir)
      return true
    } catch {
      return false
    }
  }

  /// Whitelisted files that actually exist in `dir`, in capture order followed
  /// by the JSON sidecar. Marker and arbitrary files never leave the device.
  private func existingFiles(in dir: URL) -> [String] {
    let entries =
      (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    let additionalSegments = entries.map(\.lastPathComponent)
      .filter(Self.isAdditionalSegment)
      .sorted()
    return (["recording.mov"] + additionalSegments + ["events.json"]).filter {
      fileManager.fileExists(atPath: dir.appendingPathComponent($0).path)
    }
  }

  private static func isAdditionalSegment(_ name: String) -> Bool {
    guard name.hasPrefix("recording-"), name.hasSuffix(".mov") else { return false }
    let digits = name.dropFirst("recording-".count).dropLast(".mov".count)
    return digits.count == 3 && digits.allSatisfy(\.isNumber) && Int(digits).map { $0 >= 2 } == true
  }

  private func presign(sessionId: String, files: [String]) async throws -> [String: String] {
    var req = URLRequest(url: config.collectorURL.appendingPathComponent("presign"))
    req.httpMethod = "POST"
    req.setValue(config.secret, forHTTPHeaderField: "x-feedback-secret")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(
      PresignRequestBody(
        app: config.app, sessionId: sessionId, files: files,
        userRef: FeedbackUserRef.resolve(configured: config.userRef)))
    let (data, resp) = try await transport.perform(req)
    guard resp.statusCode == 200 else {
      throw FeedbackUploadError.missingPresignedURL("presign status \(resp.statusCode)")
    }
    return try JSONDecoder().decode(PresignResponse.self, from: data).urls
  }

  /// Sweeps every session dir under the outbox root. Only USER-CONFIRMED dirs
  /// (containing a `.confirmed` marker written at Upload-tap) are ever uploaded:
  /// a non-empty dir without the marker is an unconfirmed complete session that
  /// the user never approved, so it is left alone while fresh and purged once
  /// older than `purgeAge` - never auto-uploaded. A dir with zero whitelisted
  /// files (a crashed session that never wrote a recording) can never upload, so
  /// it too is purged once stale. Empty/unconfirmed dirs are only purged once
  /// older than `purgeAge` - a freshly created dir may belong to a session whose
  /// writer has not produced its first file yet, and purging it would destroy a
  /// live recording.
  /// Safe to call on app launch. Returns the sweep tally for a result HUD.
  ///
  /// `interruptedRetention` caps how long an unanswered `.interrupted` partial is
  /// preserved from the offer flow (#472 NEW-3): it is protected from the sweep
  /// while fresh so an offer can't be deleted mid-review, but purged once older
  /// than this so unanswered offers cannot accumulate unbounded. Defaults to 7
  /// days (well beyond `purgeAge`, so a normal partial is offered across many
  /// launches first).
  @discardableResult
  public func retryOutbox(
    purgeAge: TimeInterval = 3600,
    interruptedRetention: TimeInterval = 7 * 24 * 3600
  ) async -> OutboxSweepResult {
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: outboxRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
    else { return OutboxSweepResult(flushed: 0, queued: 0, purged: 0) }
    var flushed = 0
    var queued = 0
    var purged = 0
    for entry in entries {
      let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      guard isDir else { continue }
      let confirmed = fileManager.fileExists(
        atPath: entry.appendingPathComponent(feedbackConfirmedMarker).path)
      // #472: a finalized-but-interrupted partial (`.interrupted` marker, a
      // `recording.mov` to send, not yet `.confirmed`) is owned by the
      // foreground resend OFFER, not this sweep. Never auto-upload it, and never
      // purge it here WHILE FRESH - so the sweep can't delete the dir out from
      // under a review sheet the offer is presenting, and the partial survives
      // across launches until the user picks Upload or Discard. (A marker-only
      // husk with no recording falls through to the stale purge below.) Once the
      // offer's Upload writes `.confirmed`, it flushes normally on a later sweep.
      // #472 NEW-3: but cap that retention - an offer the user never answers is
      // purged once older than `interruptedRetention` so partials cannot grow
      // unbounded.
      let interrupted = fileManager.fileExists(
        atPath: entry.appendingPathComponent(feedbackInterruptedMarker).path)
      let hasRecording = fileManager.fileExists(
        atPath: entry.appendingPathComponent("recording.mov").path)
      if interrupted, hasRecording, !confirmed {
        purgeIfStale(entry, purgeAge: interruptedRetention, purged: &purged)
        continue
      }
      if existingFiles(in: entry).isEmpty {
        purgeIfStale(entry, purgeAge: purgeAge, purged: &purged)
        continue
      }
      // Non-empty dir: only user-confirmed sessions are ever uploaded. An
      // unconfirmed complete session (finalized to the outbox but never
      // confirmed in the review sheet) is left alone while fresh and purged
      // once stale, exactly like an empty dir - it must never auto-upload.
      guard confirmed else {
        purgeIfStale(entry, purgeAge: purgeAge, purged: &purged)
        continue
      }
      if await flush(sessionId: entry.lastPathComponent) {
        flushed += 1
      } else {
        queued += 1
      }
    }
    return OutboxSweepResult(flushed: flushed, queued: queued, purged: purged)
  }

  /// Removes `entry` and bumps `purged` only once it is older than `purgeAge`
  /// AND the removal actually succeeded - a failed delete leaves the dir on
  /// disk, so counting it purged would misreport the sweep (same honesty rule
  /// as `flush`, which returns false when the dir cannot be removed).
  /// Unknown age reads as FRESH (never purge) - a `.distantPast` fallback would
  /// purge any dir whose timestamp cannot be read, destroying a live recording.
  private func purgeIfStale(_ entry: URL, purgeAge: TimeInterval, purged: inout Int) {
    let modified =
      (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate ?? Date()
    guard Date().timeIntervalSince(modified) > purgeAge else { return }
    do {
      try fileManager.removeItem(at: entry)
      purged += 1
    } catch {
      // Retained on disk: next launch's sweep tries again.
    }
  }
}
