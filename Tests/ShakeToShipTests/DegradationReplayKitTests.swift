import Testing

@testable import ShakeToShip

@Suite struct DegradationReplayKitTests {
  @Test func unavailableReplayKitRemovesOnlyTheRecordAffordance() async {
    let composerCapabilities: Capabilities = [.screenRecording, .photoLibrary, .text]
    let recordingAvailable = await FeedbackRecordingAvailability.current(
      capabilities: composerCapabilities, read: { false })
    let textOnlyProbe = DegradationReplayKitAvailabilityProbe()
    let textOnlyAvailable = await FeedbackRecordingAvailability.current(
      capabilities: [.photoLibrary, .text], read: { await textOnlyProbe.read() })

    #expect(
      FeedbackComposerRules.showsRecordAction(
        capabilities: composerCapabilities, recordingAvailable: recordingAvailable) == false)
    #expect(
      FeedbackComposerRules.shakeDestination(
        capabilities: composerCapabilities, recordingAvailable: recordingAvailable) == .composer)
    #expect(
      FeedbackComposerRules.showsRecordAction(
        capabilities: [.photoLibrary, .text], recordingAvailable: true) == false)
    #expect(textOnlyAvailable == false)
    #expect(await textOnlyProbe.calls == 0)
  }
}

private actor DegradationReplayKitAvailabilityProbe {
  private(set) var calls = 0

  func read() -> Bool {
    calls += 1
    return true
  }
}
