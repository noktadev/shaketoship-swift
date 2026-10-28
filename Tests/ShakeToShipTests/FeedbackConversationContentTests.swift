import Foundation
import Testing
@testable import ShakeToShip

struct FeedbackConversationContentTests {
  @Test func teamMessageSupportsReviewRecordingAndEditableReply() {
    let content = FeedbackConversationContent(text: """
      Here are your options.
      [Review us now](https://apps.apple.com/app/id6788269496?action=write-review)
      [Let me show you](shaketoship://record)
      [Yes, offline](shaketoship://reply?text=Yes%2C%20offline)
      """, allowsActions: true)
    #expect(content.text == "Here are your options.")
    #expect(content.actions.map(\.label) == ["Review us now", "Let me show you", "Yes, offline"])
    #expect(content.actions[0].kind == .link(URL(string: "https://apps.apple.com/app/id6788269496?action=write-review")!))
    #expect(content.actions[1].kind == .recordScreen)
    #expect(content.actions[2].kind == .reply("Yes, offline"))
  }

  @Test func userAndAgentMessagesNeverBecomeControls() {
    let text = "[Record](shaketoship://record)"
    for message in [
      FeedbackConversationMessage(id: "1", role: .user, text: text, isTeamMessage: true),
      FeedbackConversationMessage(id: "2", role: .assistant, text: text),
      FeedbackConversationMessage(id: "3", role: .notice, text: text, isTeamMessage: true),
    ] {
      #expect(message.content.text == text)
      #expect(message.content.actions.isEmpty)
    }
    #expect(FeedbackConversationMessage(id: "4", role: .assistant, text: text, isTeamMessage: true).content.actions.count == 1)
  }

  @Test(arguments: [
    "javascript:alert(1)", "file:///etc/hosts", "http://example.com", "https://user:password@example.com",
    "shaketoship://unknown", "shaketoship://record?extra=1", "shaketoship://record/path",
    "shaketoship://reply?text=", "shaketoship://reply?text=a&text=b", "shaketoship://record#fragment",
  ]) func unsupportedActionsRemainVisible(_ target: String) {
    let text = "[Action](\(target))"
    let content = FeedbackConversationContent(text: text, allowsActions: true)
    #expect(content.text == text)
    #expect(content.actions.isEmpty)
  }

  @Test func inlineLinksAndExcessActionsKeepTheirText() {
    let inline = "See [details](https://example.com) for more."
    #expect(FeedbackConversationContent(text: inline, allowsActions: true).text == inline)
    let link = "[Details](https://example.com)"
    let content = FeedbackConversationContent(text: Array(repeating: link, count: 4).joined(separator: "\n"), allowsActions: true)
    #expect(content.actions.count == 3)
    #expect(Set(content.actions.map(\.id)).count == 3)
    #expect(content.text == link)
  }

  @Test func codeExamplesRemainPlainText() {
    for marker in ["```", "~~~"] {
      let text = marker + "text\n[Record](shaketoship://record)\n" + marker
      let content = FeedbackConversationContent(text: text, allowsActions: true)
      #expect(content.text == text)
      #expect(content.actions.isEmpty)
    }
    for text in ["    [Record](shaketoship://record)", "\t[Record](shaketoship://record)",
      "````text\n```\n[Record](shaketoship://record)\n````"] {
      #expect(FeedbackConversationContent(text: text, allowsActions: true).actions.isEmpty)
    }
  }

  @Test func mixedCaseSchemesAndEncodedNewlinesAreSupported() {
    let content = FeedbackConversationContent(text: """
      [ Website ](HTTPS://example.com)
      [Reply](SHAKETOSHIP://REPLY?text=First%0ASecond)
      [Record](SHAKETOSHIP://RECORD)
      Keep this explanation.
      """, allowsActions: true)
    #expect(content.actions.count == 3)
    #expect(content.actions[0].label == "Website")
    #expect(content.actions[1].kind == .reply("First\nSecond"))
    #expect(content.actions[2].kind == .recordScreen)
    #expect(content.text == "Keep this explanation.")
  }

  @Test func windowsNewlinesAndTargetLimits() {
    let content = FeedbackConversationContent(text: "First\r\nSecond\r\n[Go](https://example.com)\r\nLast", allowsActions: true)
    #expect(content.text == "First\nSecond\nLast")
    let prefix = "https://example.com/"
    let target = prefix + String(repeating: "a", count: 2048 - prefix.utf16.count)
    #expect(FeedbackConversationContent(text: "[Go](\(target))", allowsActions: true).actions.count == 1)
    let oversized = "[Go](\(target)a)"
    #expect(FeedbackConversationContent(text: oversized, allowsActions: true).text == oversized)
    #expect(FeedbackConversationContent(text: oversized, allowsActions: true).actions.isEmpty)
  }

  @Test func oversizedAndEmptyLabelsRemainText() {
    for text in ["[ ](https://example.com)", "[\(String(repeating: "x", count: 81))](https://example.com)",
      "[Reply](shaketoship://reply?text=\(String(repeating: "x", count: 1001)))"] {
      let content = FeedbackConversationContent(text: text, allowsActions: true)
      #expect(content.text == text)
      #expect(content.actions.isEmpty)
    }
  }
}
