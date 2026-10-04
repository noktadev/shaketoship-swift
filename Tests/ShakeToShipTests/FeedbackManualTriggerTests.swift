import Testing
import Observation

@testable import ShakeToShip

@MainActor
@Suite struct FeedbackManualTriggerTests {
  /// The tray's record control is the whole request: each tap reaches the recorder once,
  /// and nothing asks a second time.
  @Test func eachRecordRequestReachesTheRecorderOnce() {
    var shakes = 0
    var recordings = 0
    FeedbackManualTrigger.register({ shakes += 1 }, recording: { recordings += 1 })
    defer { FeedbackManualTrigger.unregister() }
    FeedbackManualTrigger.signalRecording()
    FeedbackManualTrigger.signalRecording()
    #expect(recordings == 2)
    #expect(shakes == 0)
  }

  @Test func availabilityNotifiesMountedObservers() async {
    FeedbackManualTrigger.unregister()
    await confirmation("recording availability changes") { changed in
      withObservationTracking {
        _ = FeedbackManualTrigger.isRecordingAvailable
      } onChange: { changed() }
      FeedbackManualTrigger.register({}, recording: {})
    }
    FeedbackManualTrigger.unregister()
  }

  @Test func availabilityRequiresRecordingHandlerAndTracksReplacement() {
    FeedbackManualTrigger.unregister()
    #expect(!FeedbackManualTrigger.isRecordingAvailable)
    FeedbackManualTrigger.register({})
    #expect(!FeedbackManualTrigger.isRecordingAvailable)
    FeedbackManualTrigger.register({}, recording: {})
    #expect(FeedbackManualTrigger.isRecordingAvailable)
    FeedbackManualTrigger.register({})
    #expect(!FeedbackManualTrigger.isRecordingAvailable)
    FeedbackManualTrigger.register({}, recording: {})
    FeedbackManualTrigger.unregister()
    #expect(!FeedbackManualTrigger.isRecordingAvailable)
  }

  @Test func gatedRequestPresentsHostConsentThenResumesRecording() {
    var optedIn = false
    var consentRequests = 0
    var recordings = 0
    FeedbackManualTrigger.register({}, recording: { recordings += 1 },
      onRecordingRequestedWhileGated: {
        guard !optedIn else { return false }
        consentRequests += 1
        return true
      })
    defer { FeedbackManualTrigger.unregister() }
    FeedbackManualTrigger.signalRecording()
    #expect(consentRequests == 1)
    #expect(recordings == 0)
    optedIn = true
    FeedbackManualTrigger.signalRecording()
    #expect(consentRequests == 1)
    #expect(recordings == 1)
  }

  @Test func explicitWalkthroughReachesConsentAtInvitationLimitButPreservesBusyGate() {
    for busy in [false, true] {
      let action = FeedbackPromptGate.action(isRecording: false, busy: busy,
        reviewPresenting: false, promptPresenting: false, promptsShown: 3,
        lastDismissedAt: 100, now: 101, explicitRecordingRequest: true)
      #expect(action == (busy ? .ignore : .showPrompt))
    }
    #expect(FeedbackPromptGate.action(isRecording: true, busy: false,
      reviewPresenting: false, promptPresenting: false, promptsShown: 3,
      lastDismissedAt: nil, now: 101, explicitRecordingRequest: true) == .ignore)
  }

  @Test func walkthroughRoutesToRecordingConsentAndTeardownDisablesIt() {
    var shake = 0
    var recording = 0
    FeedbackManualTrigger.register({ shake += 1 }, recording: { recording += 1 })
    FeedbackManualTrigger.signalRecording()
    #expect(recording == 1)
    #expect(shake == 0)
    FeedbackManualTrigger.unregister()
    FeedbackManualTrigger.signalRecording()
    #expect(recording == 1)
  }

  @Test func signalFiresRegisteredHandler() {
    var fired = 0
    FeedbackManualTrigger.register { fired += 1 }
    FeedbackManualTrigger.signal()
    #expect(fired == 1)
    FeedbackManualTrigger.unregister()
  }

  @Test func signalAfterUnregisterIsNoOp() {
    var fired = 0
    FeedbackManualTrigger.register { fired += 1 }
    FeedbackManualTrigger.unregister()
    FeedbackManualTrigger.signal()
    #expect(fired == 0)
  }

  @Test func laterRegisterReplacesEarlierHandler() {
    var firstFired = 0
    var secondFired = 0
    FeedbackManualTrigger.register { firstFired += 1 }
    FeedbackManualTrigger.register { secondFired += 1 }
    FeedbackManualTrigger.signal()
    #expect(firstFired == 0)
    #expect(secondFired == 1)
    FeedbackManualTrigger.unregister()
  }
}
