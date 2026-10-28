import Foundation

/// Presentation values supplied by the conversation owner. A view never invents a reply
/// or promotes an upload receipt into an agent response.
struct FeedbackConversationMessage: Identifiable, Equatable, Sendable {
  enum Role: String, Codable, Sendable { case user, assistant, notice }
  enum Delivery: Equatable, Sendable {
    case sending, queued, sent, failed, waitingReply
    /// Use only after an authoritative server signal confirms analysis has started.
    case analyzing
    var label: String {
      switch self {
      case .waitingReply: "Message received. Waiting for a reply."
      case .sending: "Sending…"
      case .queued: "Saved on this device. Waiting to send."
      case .sent: "Sent"
      case .failed: "Delivery not confirmed"
      case .analyzing: "Recording received. Analysis is in progress."
      }
    }
  }
  let id: String
  let role: Role
  var text: String
  var media: [FeedbackMediaItem] = []
  var delivery: Delivery?
  var canRetry = true
  var isTeamMessage = false

  var content: FeedbackConversationContent {
    FeedbackConversationContent(text: text, allowsActions: role == .assistant && isTeamMessage)
  }
}

/// Reuses the report composer's capability and attachment rules.
struct FeedbackConversationInput: Equatable, Sendable {
  var text = ""
  var media: [FeedbackMediaItem] = []
  var isSending = false
  var deliveryPending = false
  var recordingRequested = false
  var capabilities: Capabilities = .microphoneFree
  var recordingAvailable = false

  var canSend: Bool {
    !isSending && !recordingRequested && FeedbackComposerRules.sendEnabled(media: media,
      note: capabilities.contains(.text) ? text : "")
  }
  var canRecord: Bool {
    !isSending && !recordingRequested && recordingAvailable && capabilities.contains(.screenRecording)
      && media.count < FeedbackAttachmentBounds.maxItems
  }
  var canAttach: Bool {
    !isSending && !recordingRequested && FeedbackComposerRules.showsAttach(capabilities: capabilities, mediaCount: media.count)
  }
  var recordingDescription: String {
    capabilities.contains(.microphone) ? "Record your screen. Voice is optional." : "Record your screen."
  }
}
