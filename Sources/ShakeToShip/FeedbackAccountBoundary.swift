import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Local privacy boundary only. Host account values never authenticate a reporter.
public enum FeedbackHostAccount: Hashable, Sendable {
  case unresolved
  case signedOut
  case signedIn(String)

  fileprivate var storageKey: String? {
    let value: String
    switch self {
    case .unresolved: return nil
    case .signedOut: value = "signed-out"
    case .signedIn(let id): value = "account:" + id
    }
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Serializes local reset before mounting feedback for a different host account.
/// A persisted hash preserves a same-account conversation across app restarts.
@MainActor @Observable
final class FeedbackAccountBoundary {
  private var readyKey: String?
  private var revision = UUID()
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private let read: () -> String?
  @ObservationIgnored private let write: (String) -> Void
  @ObservationIgnored private let reset: () async throws -> Void

  init(read: @escaping () -> String?, write: @escaping (String) -> Void,
    reset: @escaping () async throws -> Void) {
    self.read = read; self.write = write; self.reset = reset
  }

  convenience init() {
    let key = "shaketoship.host-account.v1"
    self.init(read: { UserDefaults.standard.string(forKey: key) },
      write: { UserDefaults.standard.set($0, forKey: key) },
      reset: {
        try await ShakeToShip.resetIdentity()
        // Also retire inactive project namespaces from earlier configurations.
        try FeedbackHubStorage.clearAllLocalIdentities()
      })
  }

  func isReady(for account: FeedbackHostAccount) -> Bool {
    guard let key = account.storageKey else { return false }
    return readyKey == key
  }

  func prepare(_ account: FeedbackHostAccount) async {
    let expected = UUID()
    revision = expected
    readyKey = nil
    let previous = pending
    let task = Task { @MainActor in
      await previous?.value
      guard revision == expected, let key = account.storageKey else { return }
      do {
        if read() != key {
          try await reset()
          // Persist only after reset. A crash before this write repeats a safe reset.
          write(key)
        }
        guard revision == expected else { return }
        readyKey = key
      } catch {
        // Keep feedback unmounted. Retry on foreground or the next account transition.
      }
    }
    pending = task
    await task.value
  }
}

#if canImport(UIKit)
private struct FeedbackAccountModifier: ViewModifier {
  let config: ShakeToShipConfig?
  let account: FeedbackHostAccount
  @State private var boundary = FeedbackAccountBoundary()
  @Environment(\.scenePhase) private var scenePhase

  func body(content: Content) -> some View {
    content.shakeToShip(config: boundary.isReady(for: account) ? config : nil)
      .task(id: account) { await boundary.prepare(account) }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active, !boundary.isReady(for: account) {
          Task { await boundary.prepare(account) }
        }
      }
  }
}

extension View {
  /// Use an unresolved account while authentication loads. The SDK clears private
  /// feedback on account changes before attaching the recorder and conversation.
  public func shakeToShip(config: ShakeToShipConfig?, account: FeedbackHostAccount) -> some View {
    modifier(FeedbackAccountModifier(config: config, account: account))
  }
}
#endif
