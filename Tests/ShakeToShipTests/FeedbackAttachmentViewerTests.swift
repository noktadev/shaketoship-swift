import Foundation
import Testing

@testable import ShakeToShip

@Suite struct FeedbackAttachmentViewerStateTests {
  private let first = FeedbackMediaItem.picked(URL(fileURLWithPath: "/tmp/first.jpg"), .image)
  private let clip = FeedbackMediaItem.recorded(URL(fileURLWithPath: "/tmp/clip.mov"))
  private let last = FeedbackMediaItem.picked(URL(fileURLWithPath: "/tmp/last.jpg"), .image)

  @Test func opensTheSelectedVideoAndKeepsMediaTypes() {
    let state = FeedbackAttachmentViewerState(
      items: [first, clip], initialSelection: clip.id, canRemove: true)
    #expect(state.selectedItem?.kind == .video)
    #expect(state.items.first?.kind == .image)
    #expect(state.indexText == "2 of 2")
  }

  @Test func missingInitialFileOpensFirstImage() {
    let state = FeedbackAttachmentViewerState(
      items: [first, clip], initialSelection: last.id, canRemove: true)
    #expect(state.selectedItem == first)
    #expect(state.indexText == "1 of 2")
  }

  @Test func selectedRemovalAdvancesRightThenLeftThenCloses() {
    var state = FeedbackAttachmentViewerState(
      items: [first, clip, last], initialSelection: clip.id, canRemove: true)
    #expect(state.removeSelected() == clip)
    #expect(state.selectedItem == last)
    #expect(state.indexText == "2 of 2")
    #expect(state.removeSelected() == last)
    #expect(state.selectedItem == first)
    #expect(state.removeSelected() == first)
    #expect(state.selection == nil)
  }

  @Test func callerRemovalKeepsAStableSelection() {
    var state = FeedbackAttachmentViewerState(
      items: [first, clip, last], initialSelection: clip.id, canRemove: false)
    state.reconcile([first, last])
    #expect(state.selectedItem == last)
    state.reconcile([first, clip, last])
    #expect(state.selectedItem == last)
    state.reconcile([])
    #expect(state.selection == nil)
  }

  @Test func readOnlyViewerCannotRemoveAnItem() {
    var state = FeedbackAttachmentViewerState(
      items: [first, clip], initialSelection: first.id, canRemove: false)
    #expect(state.removeSelected() == nil)
    #expect(state.items == [first, clip])
    #expect(state.selectedItem == first)
  }
}
