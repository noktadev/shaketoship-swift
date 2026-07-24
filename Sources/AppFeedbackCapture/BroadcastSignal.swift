import Dispatch
import Foundation
// notify(3) itself. Not re-exported by Foundation, and its `notify` clang
// module is what carries `notify_post` / `notify_register_dispatch`.
import notify

/// The three cross-process signals the broadcast extension and the host app
/// exchange, named per App Group.
///
/// Darwin notifications are a SYSTEM-WIDE namespace: every process on the
/// device that registers a given name receives every post of it. LiveKit's
/// reference implementation uses the fixed strings `iOS_BroadcastStarted` /
/// `iOS_BroadcastStopped` / `iOS_BroadcastRequestStop`, which means two apps
/// built on it can drive each other's broadcast state - and would drive ours,
/// since a customer app may embed both SDKs. Deriving the names from the App
/// Group identifier (already unique per host bundle id) removes that class of
/// bug entirely.
///
/// The payload channel is the App Group container, never these notifications:
/// notify(3) carries a name and nothing else.
public struct BroadcastSignals: Sendable, Equatable {
  /// Posted by the extension once it has minted a session directory.
  public let started: String
  /// Posted by the extension after it finalizes the manifest.
  public let stopped: String
  /// Posted by the HOST app; the extension observes it and calls
  /// `finishBroadcastWithoutError`.
  public let requestStop: String

  public init(appGroupIdentifier: String) {
    started = "\(appGroupIdentifier).broadcastStarted"
    stopped = "\(appGroupIdentifier).broadcastStopped"
    requestStop = "\(appGroupIdentifier).broadcastRequestStop"
  }

  /// Convenience for the common case: signals for the App Group this SDK
  /// derives from the host app's bundle id.
  public init(hostBundleId: String) {
    self.init(
      appGroupIdentifier: BroadcastContainer.appGroupIdentifier(hostBundleId: hostBundleId))
  }
}

/// A live Darwin notification registration. Cancels itself on deinit, so an
/// owner that is torn down cannot leave a callback pointing at freed state.
public final class DarwinSignalObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var token: Int32?

  init(token: Int32) {
    self.token = token
  }

  /// Idempotent: a second cancel (including the one from `deinit` after an
  /// explicit cancel) is a no-op rather than a double `notify_cancel`.
  public func cancel() {
    lock.lock()
    let live = token
    token = nil
    lock.unlock()
    if let live { notify_cancel(live) }
  }

  deinit { cancel() }
}

/// Thin wrapper over notify(3), the transport underneath Darwin notifications.
///
/// `notify_post` is exactly what `CFNotificationCenterPostNotification` on the
/// Darwin notify center calls, so a peer process using the CoreFoundation API
/// with the same name interoperates with this one - the extension side is free
/// to use either. We use notify(3) directly because
/// `notify_register_dispatch` delivers on a dispatch queue, whereas the
/// CoreFoundation observer API needs a running run loop on the registering
/// thread: an extension teardown path (or a test) cannot rely on that.
public enum DarwinSignals {
  /// Fire-and-forget. There is no delivery guarantee and no payload: a post
  /// while no one is registered is simply lost, and N posts can coalesce into
  /// fewer callbacks. Treat every signal as "something changed, go look at the
  /// container", never as a count.
  public static func post(_ name: String) {
    notify_post(name)
  }

  /// Registers `handler` for `name`, delivered on `queue`. Returns nil when
  /// notifyd refuses the registration (a malformed name, or the per-process
  /// token limit) - callers must treat nil as "state will not update", not as
  /// success.
  public static func observe(
    _ name: String,
    queue: DispatchQueue = DispatchQueue(label: "app-feedback.darwin-signals"),
    handler: @escaping @Sendable () -> Void
  ) -> DarwinSignalObservation? {
    var token: Int32 = 0
    let status = notify_register_dispatch(name, &token, queue) { _ in handler() }
    // `NOTIFY_STATUS_OK` is a bare `#define ... 0` that the Swift importer does
    // not surface, so the literal stands in for it. Any non-zero status is a
    // failed registration (`NOTIFY_STATUS_INVALID_NAME`, resource limits, ...);
    // the token is meaningless then and must not be cancelled.
    guard status == 0 else { return nil }
    return DarwinSignalObservation(token: token)
  }
}
