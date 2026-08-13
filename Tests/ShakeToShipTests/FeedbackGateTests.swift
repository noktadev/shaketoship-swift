import Foundation
import Testing

@testable import ShakeToShip

/// The runtime gate is the inertness proof: a nil config must attach nothing.
@Suite struct FeedbackAttachDecisionTests {
  private func config() -> ShakeToShipConfig {
    ShakeToShipConfig(app: "test", collectorURL: URL(string: "https://example.com")!, secret: "s")
  }

  @Test func attachesWhenConfigPresent() {
    #expect(FeedbackGate.shouldAttach(config: config()) == true)
  }

  @Test func passthroughWhenConfigNil() {
    #expect(FeedbackGate.shouldAttach(config: nil) == false)
  }
}

/// Cooldown + rate-cap decide whether a shake surfaces the "Something wrong?"
/// prompt. Extracted pure so the walking-with-phone nag loop is unit-tested
/// without a live UIKit responder / recorder.
@Suite struct FeedbackPromptGateTests {
  private let cooldown = FeedbackPromptGate.cooldownSeconds
  private let cap = FeedbackPromptGate.maxPromptsPerSession

  private func action(
    isRecording: Bool = false,
    busy: Bool = false,
    reviewPresenting: Bool = false,
    promptPresenting: Bool = false,
    promptsShown: Int = 0,
    lastDismissedAt: TimeInterval? = nil,
    now: TimeInterval = 1000
  ) -> FeedbackShakeAction {
    FeedbackPromptGate.action(
      isRecording: isRecording, busy: busy, reviewPresenting: reviewPresenting,
      promptPresenting: promptPresenting,
      promptsShown: promptsShown, lastDismissedAt: lastDismissedAt, now: now)
  }

  /// A shake while the prompt is already up is ignored - no re-count, no re-emit.
  @Test func promptAlreadyPresentingSuppresses() {
    #expect(action(promptPresenting: true) == .ignore)
  }

  @Test func idleShakeShowsPrompt() {
    #expect(action() == .showPrompt)
  }

  /// A shake while recording always stops - takes priority over every suppressor.
  @Test func recordingShakeStopsEvenWhenSuppressed() {
    #expect(
      action(isRecording: true, busy: true, promptsShown: 99, lastDismissedAt: 999) == .stopRecording)
  }

  @Test func busyOrReviewingSuppresses() {
    #expect(action(busy: true) == .ignore)
    #expect(action(reviewPresenting: true) == .ignore)
  }

  @Test func rateCapSuppressesAfterMaxPrompts() {
    #expect(action(promptsShown: cap - 1) == .showPrompt)
    #expect(action(promptsShown: cap) == .ignore)
    #expect(action(promptsShown: cap + 1) == .ignore)
  }

  @Test func cooldownSuppressesUntilElapsed() {
    // Dismissed at t=1000; still inside the 60s cooldown.
    #expect(action(lastDismissedAt: 1000, now: 1000 + cooldown - 1) == .ignore)
    // Exactly at the boundary the cooldown is over.
    #expect(action(lastDismissedAt: 1000, now: 1000 + cooldown) == .showPrompt)
    #expect(action(lastDismissedAt: 1000, now: 1000 + cooldown + 5) == .showPrompt)
  }

  /// No prior dismissal = no cooldown gate.
  @Test func noDismissalMeansNoCooldown() {
    #expect(action(lastDismissedAt: nil) == .showPrompt)
  }
}
