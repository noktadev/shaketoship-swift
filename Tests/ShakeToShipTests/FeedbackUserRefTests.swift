import Foundation
import Testing

@testable import ShakeToShip

@Suite struct FeedbackUserRefTests {
  private func freshDefaults() -> UserDefaults {
    let suite = "userref-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test func hostConfiguredRefWinsVerbatim() {
    let defaults = freshDefaults()
    #expect(FeedbackUserRef.resolve(configured: "user-42", defaults: defaults) == "user-42")
    // Never persisted: the host value is authoritative each call.
    #expect(defaults.string(forKey: FeedbackUserRef.defaultsKey) == nil)
  }

  @Test func overlongHostRefTruncatesToIngestCap() {
    let defaults = freshDefaults()
    let long = String(repeating: "x", count: 300)
    let resolved = FeedbackUserRef.resolve(configured: long, defaults: defaults)
    #expect(resolved.count == FeedbackUserRef.maxLength)
  }

  @Test func anonymousRefIsGeneratedOnceAndStable() {
    let defaults = freshDefaults()
    let first = FeedbackUserRef.resolve(configured: nil, defaults: defaults)
    let second = FeedbackUserRef.resolve(configured: nil, defaults: defaults)
    #expect(first.hasPrefix("anon-"))
    #expect(first == second)
    #expect(defaults.string(forKey: FeedbackUserRef.defaultsKey) == first)
  }

  @Test func emptyConfiguredRefFallsBackToAnonymous() {
    let defaults = freshDefaults()
    let resolved = FeedbackUserRef.resolve(configured: "", defaults: defaults)
    #expect(resolved.hasPrefix("anon-"))
  }

  @Test func trailCarriesUserRefIntoSession() {
    let trail = FeedbackTrail()
    trail.startSession(
      sessionId: "s1", app: "dotself", build: "1", startedAt: "T", userRef: "anon-abc")
    let session = trail.stop()
    #expect(session.user_ref == "anon-abc")
  }

  @Test func sessionEncodesUserRefAndDecodesLegacyPayloadsWithoutIt() throws {
    let session = FeedbackSession(
      session_id: "s1", app: "dotself", build: "1", started_at: "T",
      user_ref: "anon-abc", events: [])
    let encoded = try JSONEncoder().encode(session)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["user_ref"] as? String == "anon-abc")

    // Pre-userRef payload (no user_ref key) still decodes.
    let legacy = Data(
      #"{"session_id":"s2","app":"a","build":"1","started_at":"T","events":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(FeedbackSession.self, from: legacy)
    #expect(decoded.user_ref == nil)
  }
}
