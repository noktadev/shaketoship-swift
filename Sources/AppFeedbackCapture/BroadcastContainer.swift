import Foundation

/// Thrown by `BroadcastContainer`'s path-producing entry points when a
/// session id can't be trusted to resolve inside its own directory.
public enum BroadcastContainerError: Error, Equatable, Sendable {
  /// `sessionId` was empty, `"."`, `".."`, or contained a path separator -
  /// any of which could make `BroadcastContainer.sessionDirectory` resolve
  /// outside that session's own directory (as far up as `broadcastsRoot`
  /// itself, or beyond it into `containerRoot`). Thrown at the chokepoint
  /// every entry point routes through, before any filesystem call is made.
  case invalidSessionId(String)
}

/// A broadcast session that is finished with the extension and waiting for the
/// host app to upload it.
public struct PendingBroadcast: Equatable, Sendable {
  public let manifest: BroadcastManifest
  /// Non-nil only when there are actual bytes to upload. A missing or empty
  /// `capture.mov` is not evidence; a truncated one is.
  public let mediaURL: URL?
  /// Observed right now, by stat-ing `mediaURL` at the moment this value was
  /// built. `manifest.byteCount`, by contrast, is whatever the writer saw at
  /// `finalize` time - the two disagree if the media was truncated or
  /// deleted afterward.
  public let byteCount: Int

  public init(manifest: BroadcastManifest, mediaURL: URL?, byteCount: Int) {
    self.manifest = manifest
    self.mediaURL = mediaURL
    self.byteCount = byteCount
  }
}

/// Filesystem layout and session lifecycle for broadcast captures, inside the
/// App Group container shared by the host app and the broadcast extension:
///
/// ```
/// group.<host-bundle-id>.shaketoship/
///   broadcasts/
///     <session-uuid>/
///       capture.mov
///       manifest.json
/// ```
///
/// `containerRoot` is injected rather than resolved internally so the whole
/// lifecycle is exercisable against a real temp directory - the seam under test
/// is the directory bookkeeping, and stubbing it out would test nothing.
public struct BroadcastContainer: Sendable {
  public let containerRoot: URL
  // FileManager isn't Sendable in this SDK. Path lookups, `createDirectory`,
  // `contentsOfDirectory`, and `removeItem` are all stateless on the
  // receiver's own fields, so concurrent calls through `self` don't race
  // each other - that much IS a blanket claim about `FileManager` itself.
  // It does NOT extend to a delegate: `removeItem` consults
  // `FileManagerDelegate.fileManager(_:shouldRemoveItemAt:)` whenever one is
  // set, which would reintroduce shared state this type doesn't control.
  // See the caller-facing contract on `init(containerRoot:fileManager:)`.
  private nonisolated(unsafe) let fileManager: FileManager

  /// - Parameter fileManager: Must be delegate-free (`.default`, or another
  ///   instance that never had `.delegate` set). A delegate-bearing
  ///   `FileManager` would make `removeItem` consult
  ///   `FileManagerDelegate.fileManager(_:shouldRemoveItemAt:)`, reintroducing
  ///   shared, non-thread-safe state that this type's concurrency safety
  ///   assumes away.
  public init(containerRoot: URL, fileManager: FileManager = .default) {
    self.containerRoot = containerRoot
    self.fileManager = fileManager
  }

  public static func appGroupIdentifier(hostBundleId: String) -> String {
    "group.\(hostBundleId).shaketoship"
  }

  /// Resolves the real App Group container. Returns nil when the group is not
  /// provisioned for this build - callers degrade to in-app capture rather than
  /// crash an extension that has no UI to report from.
  public static func inAppGroup(
    hostBundleId: String, fileManager: FileManager = .default
  ) -> BroadcastContainer? {
    guard
      let url = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier(hostBundleId: hostBundleId))
    else { return nil }
    return BroadcastContainer(containerRoot: url, fileManager: fileManager)
  }

  public var broadcastsRoot: URL {
    containerRoot.appendingPathComponent("broadcasts", isDirectory: true)
  }

  /// The chokepoint every other entry point (`mint`, `discard`, `mediaURL`,
  /// `manifestURL`, and transitively `readManifest`/`finalize`/`write`)
  /// routes through to turn a session id into a path. `appendingPathComponent`
  /// does not sanitize its input: an empty id resolves to `broadcastsRoot`
  /// itself, and `".."` resolves - at the filesystem level, once a
  /// `FileManager` call actually touches the path - to whatever is above it,
  /// escaping `broadcastsRoot` entirely. Rejecting those shapes here, before
  /// any path is even built for the other shapes, means no caller can
  /// construct a `discard` or `mint` that lands outside its own session
  /// directory, without duplicating the check at every call site.
  public func sessionDirectory(_ sessionId: String) throws -> URL {
    guard !sessionId.isEmpty, sessionId != ".", sessionId != "..", !sessionId.contains("/") else {
      throw BroadcastContainerError.invalidSessionId(sessionId)
    }
    return broadcastsRoot.appendingPathComponent(sessionId, isDirectory: true)
  }

  public func mediaURL(_ sessionId: String) throws -> URL {
    try sessionDirectory(sessionId).appendingPathComponent("capture.mov")
  }

  public func manifestURL(_ sessionId: String) throws -> URL {
    try sessionDirectory(sessionId).appendingPathComponent("manifest.json")
  }

  /// Creates the session directory and publishes a `.recording` manifest before
  /// a single byte of media is written. If the extension dies one instruction
  /// later, the sweep still finds the session and can classify it.
  @discardableResult
  public func mint(
    sessionId: String,
    startedAt: Date,
    appBundleId: String,
    sdkVersion: String,
    hasNarration: Bool,
    hasAppAudio: Bool,
    capSeconds: Double
  ) throws -> BroadcastManifest {
    try fileManager.createDirectory(
      at: sessionDirectory(sessionId), withIntermediateDirectories: true)
    let manifest = BroadcastManifest(
      sessionId: sessionId,
      startedAt: startedAt,
      appBundleId: appBundleId,
      sdkVersion: sdkVersion,
      hasNarration: hasNarration,
      hasAppAudio: hasAppAudio,
      capSeconds: capSeconds,
      state: .recording)
    try write(manifest, to: sessionId)
    return manifest
  }

  public func readManifest(_ sessionId: String) throws -> BroadcastManifest {
    let data = try Data(contentsOf: manifestURL(sessionId))
    return try BroadcastManifest.decoder.decode(BroadcastManifest.self, from: data)
  }

  /// Rewrites the manifest in a terminal state, stamping duration and the byte
  /// count of whatever media actually landed (0 when the writer never created
  /// the file).
  ///
  /// - Parameter observedAudioTracks: The audio tracks that actually received a
  ///   sample, when the caller knows. Only the writer knows this - a track is
  ///   configured before anyone can tell whether the mic is live or the app is
  ///   silent - so `mint` cannot declare it and the flags are corrected here.
  ///   Pass `nil` (the default) to leave whatever the manifest already claims,
  ///   which is what `sweep` does: a session it reclassifies as `.aborted`
  ///   never got a `finalize` from the extension, so nobody observed its tracks
  ///   and its flags stay as minted. Consumers must treat the flags on an
  ///   `.aborted` manifest as unknown rather than as "no audio".
  @discardableResult
  public func finalize(
    sessionId: String, state: BroadcastManifest.State, durationSeconds: Double,
    observedAudioTracks: Set<CaptureAudioTrack>? = nil
  ) throws -> BroadcastManifest {
    var manifest = try readManifest(sessionId)
    if let observedAudioTracks {
      manifest.hasNarration = observedAudioTracks.contains(.narration)
      manifest.hasAppAudio = observedAudioTracks.contains(.appAudio)
    }
    // The directory name is authoritative, not the body's own claim (see
    // `write`'s doc comment) - correct it here too so a divergent embedded
    // `sessionId` is durably repaired the moment this session is finalized,
    // not just papered over in a caller's in-memory copy.
    manifest.sessionId = sessionId
    manifest.state = state
    manifest.durationSeconds = durationSeconds
    manifest.byteCount = try byteCount(of: mediaURL(sessionId))
    try write(manifest, to: sessionId)
    return manifest
  }

  /// Writes `manifest` into the session directory named `sessionId` - the
  /// directory name is authoritative, not `manifest.sessionId`. Every other
  /// entry point (`readManifest`, `finalize`, `mediaURL`) keys off the
  /// caller-supplied directory name too; if a manifest's embedded `sessionId`
  /// ever diverged from its directory (a restored device backup, a hand-edited
  /// container), trusting the file body here would let `finalize` read one
  /// directory and silently clobber a sibling session's manifest instead.
  func write(_ manifest: BroadcastManifest, to sessionId: String) throws {
    let data = try BroadcastManifest.encoder.encode(manifest)
    try data.write(to: manifestURL(sessionId), options: .atomic)
  }

  /// Size of `url` in bytes, or `0` if it doesn't exist. `0` also covers a
  /// stat failure on a file that does exist (permissions, a mid-write race) -
  /// callers must not read `0` as proof the file is absent; it means "nothing
  /// usable here" either way.
  func byteCount(of url: URL) -> Int {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return values?.fileSize ?? 0
  }

  /// Everything the host app should consider for upload, oldest first.
  ///
  /// Classification is the point of this method. A directory still marked
  /// `.recording` past `staleAfter` cannot have a live writer behind it - the
  /// extension was killed - so it is durably rewritten to `.aborted`. Its
  /// partial `.mov` is kept and surfaced: a truncated recording of the bug is
  /// worth far more than a tidy empty directory. A `.recording` directory
  /// INSIDE the window is skipped untouched, because an extension may be
  /// appending to it at this instant.
  ///
  /// The rewrite to `.aborted` can itself fail (file protection while the
  /// device is locked, a race with a second host process). When it does, the
  /// entry is still returned rather than dropped, still reporting
  /// `manifest.state == .recording` - callers must treat any `.recording`
  /// entry in the returned array as stale and unrepaired, never as still
  /// live, since a genuinely fresh `.recording` session never reaches this
  /// array at all.
  ///
  /// That "cannot have a live writer" claim is only as good as the caller's
  /// choice of `staleAfter`: it must exceed the largest `capSeconds` this app
  /// ever mints a session with, plus slack for the extension to tear down
  /// after hitting the cap. Pick it too small and a session still legitimately
  /// recording within its cap gets reclassified `.aborted` mid-flight, and a
  /// follow-up `discard` would delete the directory out from under the
  /// extension that is still writing to it.
  public func sweep(now: Date, staleAfter: TimeInterval) throws -> [PendingBroadcast] {
    guard fileManager.fileExists(atPath: broadcastsRoot.path) else { return [] }
    let entries = try fileManager.contentsOfDirectory(
      at: broadcastsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

    var pending: [PendingBroadcast] = []
    for entry in entries {
      let sessionId = entry.lastPathComponent
      // A directory whose manifest is missing or corrupt tells us nothing we
      // can act on; skipping beats throwing and hiding every healthy sibling.
      guard var manifest = try? readManifest(sessionId) else { continue }
      // The directory name is authoritative, not whatever the manifest body
      // claims (see `write`'s doc comment) - correct it unconditionally so
      // every path out of this loop, including a failed reclassification
      // below, returns an id callers can safely hand back to `discard`.
      manifest.sessionId = sessionId

      if manifest.state == .recording {
        guard now.timeIntervalSince(manifest.startedAt) > staleAfter else { continue }
        // The rewrite can fail independently of the read that already
        // succeeded above: the manifest could be under file protection while
        // the device is locked, or a second host process could have raced
        // this directory away. A failure here must not propagate out of
        // `sweep` and discard the `pending` array already built for healthy
        // siblings - it is surfaced instead with its un-rewritten `.recording`
        // manifest, so the evidence is still offered and the repair is
        // retried on the next sweep.
        //
        // `durationSeconds ?? 0` here means "never measured", not "measured
        // as instantaneous" - a killed session with 900 bytes of media still
        // gets stamped 0. Do not read this field as a real duration; derive
        // duration from the media itself if you need to meter it.
        // `finalize` already stamps the corrected `sessionId` into the value
        // it returns (and durably, into the manifest it writes to disk) - no
        // need to repeat that assignment here.
        if let finalized = try? finalize(
          sessionId: sessionId,
          state: .aborted,
          durationSeconds: manifest.durationSeconds ?? 0)
        {
          manifest = finalized
        }
      }

      let media = try mediaURL(sessionId)
      let bytes = byteCount(of: media)
      pending.append(
        PendingBroadcast(manifest: manifest, mediaURL: bytes > 0 ? media : nil, byteCount: bytes))
    }
    return pending.sorted { $0.manifest.startedAt < $1.manifest.startedAt }
  }

  /// Drops a session once the host app has uploaded (or given up on) it.
  /// Idempotent: discarding an already-gone or never-minted session is a
  /// no-op, not an error - a second host process can remove the same
  /// directory between a caller's existence check and this call, so the
  /// check-then-act shape is replaced with a catch on the specific "already
  /// gone" error instead of a `fileExists` guard that the race could still
  /// slip past.
  ///
  /// Throws `BroadcastContainerError.invalidSessionId` without touching the
  /// filesystem at all for an id that is empty, `"."`, `".."`, or contains a
  /// path separator - `sessionDirectory` rejects those before this method
  /// ever calls `removeItem`, so a caller can never turn a bad id into a
  /// recursive delete of every other pending session.
  public func discard(sessionId: String) throws {
    do {
      try fileManager.removeItem(at: sessionDirectory(sessionId))
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}
