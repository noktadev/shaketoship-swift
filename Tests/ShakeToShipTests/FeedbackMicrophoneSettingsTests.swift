import Foundation
import Testing

@testable import ShakeToShip

/// Review, recording cursor, and host settings all share the SDK preference.
/// Storage tests prove that all writes affect the recorder. The source guard
/// in `scripts/microphone-mute-one-source.test.ts` checks the view bindings.
@Suite struct FeedbackMicrophoneSettingsParityTests {
  private func freshDefaults() -> (UserDefaults, String) {
    let suite = "shaketoship.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
  }

  /// A review row writing through `@AppStorage` is a plain `set(_:forKey:)`
  /// on the same key. The recorder must see it.
  @Test func aReviewWriteIsSeenByTheRecorder() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(true, forKey: FeedbackMicrophonePreference.storageKey)
    #expect(FeedbackMicrophonePreference(defaults: defaults).isMuted == true)

    defaults.set(false, forKey: FeedbackMicrophonePreference.storageKey)
    #expect(FeedbackMicrophonePreference(defaults: defaults).isMuted == false)
  }

  /// And the other direction: the cursor's write is what the review row reads
  /// back, so the row shows the state the bar left rather than a stale copy.
  @Test func aCursorWriteIsSeenByReview() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    FeedbackMicrophonePreference(defaults: defaults).setMuted(true)
    #expect(defaults.bool(forKey: FeedbackMicrophonePreference.storageKey) == true)

    FeedbackMicrophonePreference(defaults: defaults).setMuted(false)
    #expect(defaults.bool(forKey: FeedbackMicrophonePreference.storageKey) == false)
  }

  /// Mute from Settings narrows the very next capture segment, exactly as
  /// mute from the bar does - `FeedbackRecorder` re-resolves the floor per
  /// segment rather than replaying the plan it started with.
  @Test func aSettingsMuteNarrowsTheNextSegment() {
    let live = FeedbackCapturePlan(startsScreenCapture: true, capturesMicrophone: true)
    #expect(FeedbackGate.planForSegment(live, microphoneMuted: true).capturesMicrophone == false)
  }

  /// The asymmetry survives a Settings unmute, which is the whole reason the
  /// gate ANDs: a recording that started muted stays muted for its entire
  /// life, whichever control the unmute came from.
  @Test func aSettingsUnmuteCannotRearmARecordingThatStartedMuted() {
    let startedMuted = FeedbackCapturePlan(startsScreenCapture: true, capturesMicrophone: false)
    #expect(
      FeedbackGate.planForSegment(startedMuted, microphoneMuted: false).capturesMicrophone == false)
  }

  /// A host that never granted `.microphone` has nothing for either control to
  /// mute: unmuting in Settings cannot raise a capability the host withheld.
  @Test func neitherControlCanExceedTheHostCeiling() {
    let config = ShakeToShipConfig(
      app: "test", collectorURL: URL(string: "https://example.com")!, secret: "s",
      capabilities: [.screenRecording, .text])
    #expect(FeedbackGate.capturePlan(for: config, microphoneMuted: false).capturesMicrophone == false)
  }
}
