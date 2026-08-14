import AVFoundation
import Foundation
import Testing

@testable import ShakeToShip

@Suite struct FeedbackCapabilitiesTests {
  static func config(
    capabilities: ShakeToShipConfig.Capabilities = .all,
    transcription: Bool = true
  ) -> ShakeToShipConfig {
    ShakeToShipConfig(
      app: "test", collectorURL: URL(string: "https://example.com")!, secret: "s",
      capabilities: capabilities, transcription: transcription)
  }

  @Test func rawValuesAreTheDocumentedBits() {
    #expect(ShakeToShipConfig.Capabilities.screenRecording.rawValue == 1 << 0)
    #expect(ShakeToShipConfig.Capabilities.microphone.rawValue == 1 << 1)
    #expect(ShakeToShipConfig.Capabilities.photoLibrary.rawValue == 1 << 2)
    #expect(ShakeToShipConfig.Capabilities.text.rawValue == 1 << 3)
  }

  @Test func allContainsEveryCapability() {
    let all = ShakeToShipConfig.Capabilities.all
    #expect(all.contains(.screenRecording))
    #expect(all.contains(.microphone))
    #expect(all.contains(.photoLibrary))
    #expect(all.contains(.text))
  }

  /// Pins the exact membership, not just the microphone's absence, so a
  /// regression that also drops `.photoLibrary` or `.text` from the default
  /// ceiling fails here instead of passing silently.
  @Test func microphoneFreeIsExactlyScreenRecordingPhotoLibraryAndText() {
    #expect(
      ShakeToShipConfig.Capabilities.microphoneFree
        == [.screenRecording, .photoLibrary, .text])
  }

  /// The top-level spelling in the chunk plan and the nested spelling in the
  /// design doc must denote one type, so chunks G and H compile either way.
  @Test func topLevelSpellingIsTheSameType() {
    #expect(Capabilities.all == ShakeToShipConfig.Capabilities.all)
  }

  @Test func defaultCeilingFailsClosedOnTheMicrophone() {
    let config = ShakeToShipConfig(
      app: "test", collectorURL: URL(string: "https://example.com")!, secret: "s")
    #expect(config.capabilities.contains(.microphone) == false)
    #expect(config.transcription == true)
    #expect(config.maxAttachmentDuration == 300)
  }

  /// The default ceiling must be safe (no microphone) without being inert: a
  /// host that installs the SDK and passes nothing still gets a working
  /// screen-recording feedback flow.
  @Test func defaultConfigCapturesNoMicrophoneButStillAttachesAndRecords() {
    let config = ShakeToShipConfig(
      app: "test", collectorURL: URL(string: "https://example.com")!, secret: "s")
    #expect(FeedbackGate.capturePlan(for: config).capturesMicrophone == false)
    #expect(FeedbackGate.shouldAttach(config: config) == true)
    #expect(FeedbackGate.capturePlan(for: config).startsScreenCapture == true)
  }

  /// Regression guard for the field-by-field config rebuild bug: `with(
  /// onFunnelEvent:onOptOut:)` must preserve a narrowed ceiling and every
  /// other field, not just the ones a rebuild happened to copy. Both
  /// callbacks passed in must also land on the copy - `with` replaces them
  /// wholesale, so a caller that supplies one must not silently lose the
  /// other.
  @Test func withPreservesANarrowedCeilingAndEveryOtherFieldAndBothCallbacks() {
    let original = ShakeToShipConfig(
      app: "test-app", collectorURL: URL(string: "https://example.com")!, secret: "s3cr3t",
      capabilities: [.text], transcription: false, maxAttachmentDuration: 42,
      maxDuration: 99, userRef: "user-123")

    let copy = original.with(onFunnelEvent: { _ in }, onOptOut: {})

    #expect(copy.capabilities == [.text])
    #expect(copy.transcription == false)
    #expect(copy.maxAttachmentDuration == 42)
    #expect(copy.app == "test-app")
    #expect(copy.collectorURL == URL(string: "https://example.com")!)
    #expect(copy.secret == "s3cr3t")
    #expect(copy.maxDuration == 99)
    #expect(copy.userRef == "user-123")
    #expect(copy.onFunnelEvent != nil)
    #expect(copy.onOptOut != nil)
  }

  /// Rule 4: one inertness rule, not two. An empty ceiling attaches nothing,
  /// exactly like a nil config: no responder, no review window, no recorder.
  @Test func emptyCapabilitySetIsInertLikeNilConfig() {
    #expect(FeedbackGate.shouldAttach(config: nil) == false)
    #expect(FeedbackGate.shouldAttach(config: Self.config(capabilities: [])) == false)
    #expect(FeedbackGate.shouldAttach(config: Self.config(capabilities: .all)) == true)
    #expect(FeedbackGate.shouldAttach(config: Self.config(capabilities: .text)) == true)
  }

  /// Rule 1: without `.screenRecording` there is no capture to start, so no
  /// ReplayKit call can be made. `FeedbackRecorder` refuses the start instead.
  @Test func noScreenRecordingCapabilityMeansNoCapture() {
    for capabilities in [[] as Capabilities, .text, .photoLibrary, [.microphone, .text]] {
      let plan = FeedbackGate.capturePlan(for: Self.config(capabilities: capabilities))
      #expect(plan.startsScreenCapture == false)
    }
    #expect(
      FeedbackGate.capturePlan(for: Self.config(capabilities: .screenRecording))
        .startsScreenCapture == true)
  }

  /// Rule 2: without `.microphone` nothing asks for the microphone, so iOS can
  /// show no microphone prompt.
  @Test func noMicrophoneCapabilityMeansNoMicrophone() {
    let plan = FeedbackGate.capturePlan(
      for: Self.config(capabilities: [.screenRecording, .text, .photoLibrary]))
    #expect(plan.startsScreenCapture == true)
    #expect(plan.capturesMicrophone == false)
  }

  /// The two bits are orthogonal: `.screenRecording` is the outer gate that
  /// decides whether capture starts at all, and `.microphone` is only ever
  /// read once that gate is open. Granting `.microphone` alone starts no
  /// capture, so it never gets the chance to record anything.
  @Test func microphoneCapabilityAloneStartsNoCapture() {
    let plan = FeedbackGate.capturePlan(for: Self.config(capabilities: .microphone))
    #expect(plan.startsScreenCapture == false)
    #expect(plan.capturesMicrophone == true)
  }

  /// The user floor: a muted install captures no microphone even when the host
  /// granted it.
  @Test func mutedUserOverridesAGrantedMicrophone() {
    let config = Self.config(capabilities: .all)
    #expect(FeedbackGate.capturePlan(for: config, microphoneMuted: false).capturesMicrophone == true)
    #expect(FeedbackGate.capturePlan(for: config, microphoneMuted: true).capturesMicrophone == false)
  }

  /// Rule 3, direction one: flipping `transcription` changes no capture bit.
  /// All four combinations are legal; none of them moves the plan.
  @Test func transcriptionNeverChangesTheCapturePlan() {
    for capabilities in [.all, [.screenRecording], [.screenRecording, .microphone]] as [Capabilities] {
      #expect(
        FeedbackGate.capturePlan(for: Self.config(capabilities: capabilities, transcription: true))
          == FeedbackGate.capturePlan(
            for: Self.config(capabilities: capabilities, transcription: false)))
    }
  }

  /// Rule 3, direction two: narration a human can hear with no stored
  /// transcript is a legal, reachable configuration.
  @Test func microphoneOnWithTranscriptionOffIsLegal() {
    let config = Self.config(capabilities: [.screenRecording, .microphone], transcription: false)
    #expect(FeedbackGate.capturePlan(for: config).capturesMicrophone == true)
    #expect(config.transcription == false)
  }

  /// Rule 3, direction two, mirrored: a stored transcript request survives a
  /// microphone the host never granted (the server obeys it; the SDK does not
  /// silently rewrite it).
  @Test func transcriptionOnWithMicrophoneOffIsLegal() {
    let config = Self.config(capabilities: [.screenRecording], transcription: true)
    #expect(FeedbackGate.capturePlan(for: config).capturesMicrophone == false)
    #expect(config.transcription == true)
  }

  /// C1: a resumed segment must re-resolve the mute floor, not replay the
  /// plan captured at recorder init. Muting between segments narrows the
  /// very next segment immediately.
  @Test func mutingBetweenSegmentsDisarmsTheMicrophone() {
    let plan = FeedbackCapturePlan(startsScreenCapture: true, capturesMicrophone: true)
    let resolved = FeedbackGate.planForSegment(plan, microphoneMuted: true)
    #expect(resolved.capturesMicrophone == false)
    #expect(resolved.startsScreenCapture == true)
  }

  /// C1, the asymmetry: a recording that started muted has `capturesMicrophone
  /// == false` baked into every plan built from it. Unmuting between segments
  /// cannot raise that bit back - AND can only narrow, never widen - so it
  /// takes effect from the next RECORDING, not the next segment.
  @Test func unmutingBetweenSegmentsCannotRearmARecordingThatStartedMuted() {
    let plan = FeedbackCapturePlan(startsScreenCapture: true, capturesMicrophone: false)
    let resolved = FeedbackGate.planForSegment(plan, microphoneMuted: false)
    #expect(resolved.capturesMicrophone == false)
  }
}

@Suite struct FeedbackMicrophonePreferenceTests {
  /// A suite name unique per test run keeps this off `.standard` and off any
  /// other test's state, while still exercising real UserDefaults persistence.
  private func freshDefaults() -> (UserDefaults, String) {
    let suite = "shaketoship.tests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
  }

  @Test func defaultsToUnmuted() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(FeedbackMicrophonePreference(defaults: defaults).isMuted == false)
  }

  /// The relaunch proof: a SECOND preference instance, built fresh over the
  /// same persistent domain the way a relaunched app builds one, sees the
  /// choice the first instance stored.
  @Test func mutePersistsAcrossASimulatedRelaunch() {
    let (defaults, suite) = freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }

    FeedbackMicrophonePreference(defaults: defaults).setMuted(true)

    let relaunched = UserDefaults(suiteName: suite)!
    #expect(FeedbackMicrophonePreference(defaults: relaunched).isMuted == true)

    FeedbackMicrophonePreference(defaults: relaunched).setMuted(false)
    let relaunchedAgain = UserDefaults(suiteName: suite)!
    #expect(FeedbackMicrophonePreference(defaults: relaunchedAgain).isMuted == false)
  }

  /// The bar's `@AppStorage` and the recorder's read must address one key.
  @Test func storageKeyIsStable() {
    #expect(FeedbackMicrophonePreference.storageKey == "shaketoship.microphone.muted")
  }
}

/// Rule 2 at the real seam: a REAL `AVAssetWriter`, no mock. Delete anything
/// here and the assertion stops being about the writer, which is the point.
@Suite struct FeedbackCaptureInputsTests {
  private func writer() throws -> (AVAssetWriter, URL) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(UUID().uuidString).mov")
    return (try AVAssetWriter(outputURL: url, fileType: .mov), url)
  }

  @Test func micDeniedAddsNoAudioInputToTheAssetWriter() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url) }

    let plan = FeedbackCapturePlan(startsScreenCapture: true, capturesMicrophone: false)
    let inputs = try FeedbackCaptureInputs.attach(plan: plan, to: writer, width: 640, height: 480)

    #expect(inputs.audio == nil)
    #expect(writer.inputs.contains { $0.mediaType == .audio } == false)
    #expect(writer.inputs.filter { $0.mediaType == .video }.count == 1)
  }

  @Test func micGrantedAddsExactlyOneAudioInput() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url) }

    let plan = FeedbackCapturePlan(startsScreenCapture: true, capturesMicrophone: true)
    let inputs = try FeedbackCaptureInputs.attach(plan: plan, to: writer, width: 640, height: 480)

    #expect(inputs.audio != nil)
    #expect(writer.inputs.filter { $0.mediaType == .audio }.count == 1)
  }

  /// Rule 1 restated where it bites: a plan that starts no capture never
  /// reaches an asset writer at all.
  @Test func aPlanThatStartsNoCaptureIsRejectedBeforeAnyInputIsAdded() throws {
    let (writer, url) = try writer()
    defer { try? FileManager.default.removeItem(at: url) }

    let plan = FeedbackCapturePlan(startsScreenCapture: false, capturesMicrophone: true)
    // `FeedbackRecorderError` is not `Equatable` (`writeFailed(Error?)` carries
    // a payload), so match the case by hand rather than `#expect(throws:)`
    // against the type. Rule 1 is the reason this chunk is held for human
    // review - a regression that throws `.setupFailed` instead of
    // `.captureNotPermitted` must fail this test, not slip through because
    // both are `FeedbackRecorderError`.
    do {
      _ = try FeedbackCaptureInputs.attach(plan: plan, to: writer, width: 640, height: 480)
      Issue.record("expected FeedbackRecorderError.captureNotPermitted, got no error")
    } catch FeedbackRecorderError.captureNotPermitted {
      // Expected.
    } catch {
      Issue.record("expected FeedbackRecorderError.captureNotPermitted, got \(error)")
    }
    #expect(writer.inputs.isEmpty)
  }
}
