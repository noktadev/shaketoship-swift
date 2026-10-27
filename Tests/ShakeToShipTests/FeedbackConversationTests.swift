import Foundation
import Testing
@testable import ShakeToShip

@Suite struct FeedbackConversationTests {
  @Test func pendingDeliveryKeepsNextDraftAndItsActionsAvailable() {
    var input = FeedbackConversationInput(text: "Next message", deliveryPending: true,
      capabilities: .all, recordingAvailable: true)
    #expect(input.canSend)
    #expect(input.canRecord)
    #expect(input.canAttach)
    input.text += " with more detail"
    input.deliveryPending = false
    #expect(input.canSend)
    #expect(input.canRecord)
    #expect(input.text == "Next message with more detail")
  }
  @Test func textCapabilityCannotBeBypassedByAStaleDraft() {
    var input = FeedbackConversationInput(text: "Saved before capabilities changed", capabilities: [.screenRecording])
    #expect(!input.canSend)
    input.media = [.recorded(URL(fileURLWithPath: "/tmp/recording.mov"))]
    #expect(input.canSend)
    input.isSending = true
    #expect(!input.canSend)
  }
  @Test func captureRequiresAvailabilityCapabilityAndFreeSlot() {
    var input = FeedbackConversationInput(capabilities: .all, recordingAvailable: true)
    #expect(input.canRecord)
    input.media = (0..<FeedbackAttachmentBounds.maxItems).map {
      .picked(URL(fileURLWithPath: "/tmp/\($0).jpg"), .image)
    }
    #expect(!input.canRecord)
    #expect(!input.canAttach)
    input.media = []
    input.recordingAvailable = false
    #expect(!input.canRecord)
    input.recordingAvailable = true
    input.capabilities = .text
    #expect(!input.canRecord)
  }
  @Test func recordingHandoffLocksActionsWithoutClaimingSend() {
    var input = FeedbackConversationInput(text: "Example", capabilities: .all, recordingAvailable: true)
    input.recordingRequested = true
    #expect(!input.canSend)
    #expect(!input.canRecord)
    #expect(!input.canAttach)
    #expect(!input.isSending)
  }
  @Test func microphoneFreeDoesNotPromiseVoiceRecording() {
    let input = FeedbackConversationInput(capabilities: .microphoneFree)
    #expect(input.recordingDescription == "Record your screen.")
  }
  @Test func queuedDoesNotClaimDeliveryOrAnalysis() {
    #expect(FeedbackConversationMessage.Delivery.queued.label == "Saved on this device. Waiting to send.")
    #expect(FeedbackConversationMessage.Delivery.analyzing.label != FeedbackConversationMessage.Delivery.sent.label)
  }
}
