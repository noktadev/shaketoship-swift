import AppFeedbackCapture
import Combine
import Foundation

/// Failures the host side of cross-app capture must never swallow.
public enum FeedbackBroadcastError: Error, Equatable, CustomStringConvertible {
  /// The App Group container could not be resolved, so the host app and the
  /// broadcast extension have no shared filesystem and there is no way to see
  /// - or upload - anything the extension recorded.
  ///
  /// This is thrown rather than degraded to an empty result on purpose. An
  /// unprovisioned group (#839: `group.<hostBundleId>.shaketoship` is
  /// provisioned nowhere yet) makes `containerURL(forSecurityApplicationGroupIdentifier:)`
  /// return nil, and "no sessions found" is exactly what a working install with
  /// nothing to upload looks like. Silently identical behaviour for "healthy"
  /// and "fundamentally misconfigured" is the worst failure mode this feature
  /// has, because the bug only surfaces as missing evidence weeks later.
  case appGroupUnavailable(identifier: String)

  public var description: String {
    switch self {
    case let .appGroupUnavailable(identifier):
      return """
        AppFeedback: App Group "\(identifier)" is unreachable. The broadcast \
        extension writes captures there and the host app reads them back, so \
        cross-app capture cannot work until the group is added to BOTH the app \
        and the extension entitlements (and to the provisioning profile).
        """
    }
  }
}

/// Outcome of one foreground harvest pass over the shared container.
public struct BroadcastHarvestResult: Equatable, Sendable {
  /// Uploaded AND removed from the container.
  public let uploaded: [String]
  /// Upload failed; the session is still on disk for the next foreground.
  public let retained: [String]
  /// Nothing to send (a session whose media never got a byte), so there is
  /// nothing to confirm an upload against. Kept, never deleted - see
  /// `FeedbackBroadcastManager.harvest`.
  public let empty: [String]

  public init(uploaded: [String], retained: [String], empty: [String]) {
    self.uploaded = uploaded
    self.retained = retained
    self.empty = empty
  }
}

/// Host-app side of cross-app broadcast capture: start one, watch it, stop it,
/// and pick up what it left behind.
///
/// A ReplayKit broadcast runs in its own process and keeps recording after this
/// app is backgrounded or killed. That is the entire point - the user is
/// reviewing some OTHER app - and it dictates the shape here:
///
/// - state crosses the process boundary as Darwin notifications, because there
///   is no shared memory and no live connection to piggyback on;
/// - the payload crosses as FILES in the App Group container, never over a
///   socket. LiveKit's reference implementation streams sample buffers to the
///   host app over a Unix socket, which requires the host to stay alive; ours
///   is deliberately suspended, so that design would lose the session.
public final class FeedbackBroadcastManager: @unchecked Sendable {
  /// How long a session may claim to be `.recording` before the host treats it
  /// as a killed extension rather than a live one.
  ///
  /// It MUST exceed the largest `capSeconds` any session is minted with, plus
  /// slack for the extension to tear down after hitting its cap - see
  /// `BroadcastContainer.sweep`. Too small and a still-live session is
  /// reclassified `.aborted` and uploaded (then deleted) out from under the
  /// extension that is still writing it. The cost of being generous is only
  /// that an aborted session waits longer for its first upload attempt; a
  /// cleanly `.finished` session is unaffected by this value entirely.
  public static let defaultStaleAfter: TimeInterval = 3600

  public let appGroupIdentifier: String
  public let signals: BroadcastSignals
  /// Bundle id handed to the picker as `preferredExtension`.
  public let preferredExtension: String?

  private let uploader: FeedbackUploader
  private let containerProvider: @Sendable () -> BroadcastContainer?
  private let pickerProvider: @MainActor @Sendable () -> BroadcastPicker?

  private let lock = NSLock()
  private var observations: [DarwinSignalObservation] = []
  private let subject = CurrentValueSubject<Bool, Never>(false)

  /// Whether a broadcast is running right now, as last reported by the
  /// extension. Best-effort by construction: notify(3) delivers no payload and
  /// guarantees no delivery, so treat this as a UI hint and the container as
  /// the source of truth about what was actually captured.
  public var isBroadcasting: Bool { subject.value }

  /// Current-value publisher for a UI to bind to; a late subscriber still
  /// receives today's state before any transition.
  public var isBroadcastingPublisher: AnyPublisher<Bool, Never> {
    subject.eraseToAnyPublisher()
  }

  /// - Parameters:
  ///   - containerProvider: Resolves the shared container. Returning nil means
  ///     the App Group is unreachable, which `harvest` reports loudly rather
  ///     than treating as "nothing to upload".
  ///   - pickerProvider: Builds the system broadcast picker. Nil on any
  ///     platform that has no ReplayKit picker, which makes `requestActivation`
  ///     report `.unavailable`.
  public init(
    appGroupIdentifier: String,
    uploader: FeedbackUploader,
    preferredExtension: String? = nil,
    containerProvider: @escaping @Sendable () -> BroadcastContainer?,
    pickerProvider: (@MainActor @Sendable () -> BroadcastPicker?)? = nil
  ) {
    self.appGroupIdentifier = appGroupIdentifier
    self.signals = BroadcastSignals(appGroupIdentifier: appGroupIdentifier)
    self.uploader = uploader
    self.preferredExtension = preferredExtension
    self.containerProvider = containerProvider
    self.pickerProvider = pickerProvider ?? FeedbackBroadcastManager.defaultPickerProvider
    observe()
  }

  /// Wires the real App Group container and the real system picker for a host
  /// app. `hostBundleId` decides the App Group name, so it must be the APP's
  /// bundle id even when this SDK is linked from somewhere else.
  public convenience init(
    config: FeedbackConfig,
    hostBundleId: String,
    outboxRoot: URL,
    transport: FeedbackTransport = URLSessionTransport(),
    bundle: Bundle = .main
  ) {
    let appGroupIdentifier = BroadcastContainer.appGroupIdentifier(hostBundleId: hostBundleId)
    self.init(
      appGroupIdentifier: appGroupIdentifier,
      uploader: FeedbackUploader(
        config: config, transport: transport, fileManager: .default, outboxRoot: outboxRoot),
      preferredExtension: FeedbackBroadcastExtension.discoverInMainBundle(bundle),
      containerProvider: { BroadcastContainer.inAppGroup(hostBundleId: hostBundleId) })
  }

  deinit {
    lock.lock()
    let live = observations
    observations = []
    lock.unlock()
    live.forEach { $0.cancel() }
  }

  private static let defaultPickerProvider: @MainActor @Sendable () -> BroadcastPicker? = {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    return SystemBroadcastPicker()
    #else
    return nil
    #endif
  }

  // MARK: - State

  private func observe() {
    let started = DarwinSignals.observe(signals.started) { [weak self] in
      self?.subject.send(true)
    }
    let stopped = DarwinSignals.observe(signals.stopped) { [weak self] in
      self?.subject.send(false)
    }
    lock.lock()
    observations = [started, stopped].compactMap { $0 }
    lock.unlock()
  }

  // MARK: - Activation

  /// Asks iOS to show the broadcast picker. One user tap plus the system's own
  /// 3-second countdown is the floor; nothing can start a broadcast silently.
  ///
  /// The returned outcome tells the caller whether the sheet is actually
  /// coming, so a UI can say so instead of waiting for a broadcast that will
  /// never start.
  @MainActor
  @discardableResult
  public func requestActivation() -> BroadcastActivationOutcome {
    guard let picker = pickerProvider() else { return .unavailable }
    return FeedbackBroadcastActivation.activate(
      picker: picker, preferredExtension: preferredExtension)
  }

  /// Asks the extension to end the broadcast. Advisory: the extension may
  /// already be gone, and the user can always stop it from the system UI
  /// instead. Either way the evidence is in the container, and `harvest` finds
  /// it.
  public func requestStop() {
    DarwinSignals.post(signals.requestStop)
  }

  // MARK: - Harvest

  /// Uploads everything the extension left in the shared container. Call it on
  /// app foreground: by then the broadcast this app never saw start may already
  /// have finished, and the container is the only record of it.
  ///
  /// Selection is `BroadcastContainer.sweep`'s: `.finished` and `.capped`
  /// sessions, plus `.recording` ones stale enough that no live writer can be
  /// behind them (reclassified `.aborted`). A `.recording` session inside its
  /// window never reaches this method - an extension may be appending to it
  /// this instant.
  ///
  /// An aborted session's truncated media is uploaded exactly like a clean one.
  /// A partial recording of the bug is still evidence, and the alternative -
  /// deleting it for being untidy - throws away the only capture of a session
  /// that, by definition, went wrong.
  ///
  /// A session is discarded ONLY after `upload` confirms every byte reached the
  /// server. Anything else (a failed presign, a rejected PUT, a session with no
  /// media to send at all) leaves the directory exactly where it is for the
  /// next foreground to retry.
  ///
  /// - Throws: `FeedbackBroadcastError.appGroupUnavailable` when the container
  ///   cannot be resolved at all. Deliberately not an empty result: see the
  ///   error's own documentation.
  @discardableResult
  public func harvest(
    now: Date = Date(), staleAfter: TimeInterval = FeedbackBroadcastManager.defaultStaleAfter
  ) async throws -> BroadcastHarvestResult {
    let container = try resolveContainer()
    let pending = try container.sweep(now: now, staleAfter: staleAfter)

    var uploaded: [String] = []
    var retained: [String] = []
    var empty: [String] = []

    for session in pending {
      let sessionId = session.manifest.sessionId
      // `mediaURL` is nil precisely when there are no bytes to upload. There is
      // then nothing an upload could confirm, so the session is reported and
      // kept rather than deleted on the strength of a vacuous success.
      guard session.mediaURL != nil else {
        empty.append(sessionId)
        continue
      }

      let directory = try container.sessionDirectory(sessionId)
      let confirmed = await uploader.upload(
        sessionId: sessionId, from: directory, files: Self.uploadedFiles)
      guard confirmed else {
        retained.append(sessionId)
        continue
      }
      // Only now. `discard` is idempotent, so a second host process racing the
      // same session is a no-op rather than an error.
      try container.discard(sessionId: sessionId)
      uploaded.append(sessionId)
    }

    return BroadcastHarvestResult(uploaded: uploaded, retained: retained, empty: empty)
  }

  /// What a broadcast session ships: the capture, and the manifest that says
  /// which tracks are inside it and how the session ended. The manifest is not
  /// derivable from the media (a truncated `.mov` cannot answer "was the mic
  /// on?"), so it is uploaded as its own object.
  private static let uploadedFiles = ["capture.mov", "manifest.json"]

  private func resolveContainer() throws -> BroadcastContainer {
    guard let container = containerProvider() else {
      throw FeedbackBroadcastError.appGroupUnavailable(identifier: appGroupIdentifier)
    }
    return container
  }
}
