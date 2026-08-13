import Testing

@testable import ShakeToShip

@MainActor
@Suite struct FeedbackManualTriggerTests {
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
