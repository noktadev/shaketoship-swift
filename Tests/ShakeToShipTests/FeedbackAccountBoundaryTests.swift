import Foundation
import Testing
@testable import ShakeToShip

@MainActor struct FeedbackAccountBoundaryTests {
  @Test func restartPreservesSameAccountButLogoutAndReplacementReset() async {
    var stored: String?
    var resets = 0
    func make() -> FeedbackAccountBoundary {
      FeedbackAccountBoundary(read: { stored }, write: { stored = $0 }, reset: { resets += 1 })
    }
    let first = make()
    await first.prepare(.unresolved)
    #expect(resets == 0)
    #expect(!first.isReady(for: .unresolved))
    await first.prepare(.signedIn("one"))
    #expect(resets == 1)
    #expect(first.isReady(for: .signedIn("one")))
    #expect(!first.isReady(for: .signedIn("two")))
    #expect(stored != "one")
    let restarted = make()
    await restarted.prepare(.signedIn("one"))
    #expect(resets == 1)
    let beforeLock = stored
    await restarted.prepare(.unresolved)
    #expect(!restarted.isReady(for: .signedIn("one")))
    #expect(stored == beforeLock)
    await restarted.prepare(.signedIn("one"))
    #expect(resets == 1)
    await restarted.prepare(.signedOut)
    #expect(resets == 2)
    await restarted.prepare(.signedIn("two"))
    #expect(resets == 3)
  }

  @Test func storageFailureKeepsFeedbackClosedUntilRetry() async {
    var stored: String?
    var fail = true
    let boundary = FeedbackAccountBoundary(read: { stored }, write: { stored = $0 }, reset: {
      if fail { throw FeedbackHubError.storage }
    })
    await boundary.prepare(.signedIn("one"))
    #expect(!boundary.isReady(for: .signedIn("one")))
    #expect(stored == nil)
    fail = false
    await boundary.prepare(.signedIn("one"))
    #expect(boundary.isReady(for: .signedIn("one")))
  }

  @Test func replacementWaitsForOldResetAndCannotPublishItsAccount() async {
    var stored: String?
    var resume: CheckedContinuation<Void, Never>?
    var resets = 0
    let boundary = FeedbackAccountBoundary(read: { stored }, write: { stored = $0 }, reset: {
      resets += 1
      if resets == 1 { await withCheckedContinuation { resume = $0 } }
    })
    let old = Task { await boundary.prepare(.signedIn("one")) }
    while resume == nil { await Task.yield() }
    let replacement = Task { await boundary.prepare(.signedIn("two")) }
    await Task.yield()
    #expect(!boundary.isReady(for: .signedIn("two")))
    resume?.resume()
    await old.value
    await replacement.value
    #expect(resets == 2)
    #expect(!boundary.isReady(for: .signedIn("one")))
    #expect(boundary.isReady(for: .signedIn("two")))
  }
}
