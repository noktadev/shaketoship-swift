import Testing

@testable import AppFeedback

@MainActor
@Suite struct FeedbackLiveActivityStopTests {
  @Test func signalFiresRegisteredHandler() async {
    var fired = 0
    FeedbackLiveActivityStop.register { fired += 1 }
    await FeedbackLiveActivityStop.signal()
    #expect(fired == 1)
    FeedbackLiveActivityStop.unregister()
  }

  @Test func signalAfterUnregisterIsNoOp() async {
    var fired = 0
    FeedbackLiveActivityStop.register { fired += 1 }
    FeedbackLiveActivityStop.unregister()
    await FeedbackLiveActivityStop.signal()
    #expect(fired == 0)
  }

  @Test func signalAwaitsAsyncHandlerCompletion() async {
    var finished = false
    FeedbackLiveActivityStop.register {
      try? await Task.sleep(nanoseconds: 20_000_000)
      finished = true
    }
    await FeedbackLiveActivityStop.signal()
    // signal() must not return before the handler's async stop path finished.
    #expect(finished)
    FeedbackLiveActivityStop.unregister()
  }
}
