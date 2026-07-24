import Foundation
import Testing

@testable import AppFeedback

/// The activation POLICY is real code under test here; only the picker view
/// itself is a double, because `RPSystemBroadcastPickerView` is UIKit/ReplayKit
/// and does not exist on the platform the suite runs on. Whether the private
/// `buttonPressed:` selector still exists on a given iOS release is a device
/// UAT question, not a unit-test one - what this suite pins is that BOTH
/// answers to that question lead somewhere the user can act on.
@MainActor
@Suite struct FeedbackBroadcastActivationTests {
  final class FakePicker: BroadcastPicker {
    var respondsToButtonPressed: Bool
    var rawPickerCanBePresented: Bool
    private(set) var configuredExtension: String??
    private(set) var configuredMicrophoneButton: Bool?
    private(set) var pressedCount = 0
    private(set) var presentedCount = 0

    init(respondsToButtonPressed: Bool, rawPickerCanBePresented: Bool = true) {
      self.respondsToButtonPressed = respondsToButtonPressed
      self.rawPickerCanBePresented = rawPickerCanBePresented
    }

    func configure(preferredExtension: String?, showsMicrophoneButton: Bool) {
      configuredExtension = preferredExtension
      configuredMicrophoneButton = showsMicrophoneButton
    }

    func pressButton() { pressedCount += 1 }

    func presentRawPicker() -> Bool {
      presentedCount += 1
      return rawPickerCanBePresented
    }
  }

  @Test func pressesTheButtonWhenThePrivateSelectorIsAvailable() {
    let picker = FakePicker(respondsToButtonPressed: true)

    let outcome = FeedbackBroadcastActivation.activate(
      picker: picker, preferredExtension: "com.example.app.broadcast")

    #expect(outcome == .pressedProgrammatically)
    #expect(picker.pressedCount == 1)
    #expect(picker.presentedCount == 0)
  }

  @Test func fallsBackToTheRawPickerViewWhenTheSelectorIsGone() {
    let picker = FakePicker(respondsToButtonPressed: false)

    let outcome = FeedbackBroadcastActivation.activate(
      picker: picker, preferredExtension: "com.example.app.broadcast")

    // The user still gets a control they can tap - never a silent no-op.
    #expect(outcome == .presentedPicker)
    #expect(picker.presentedCount == 1)
    #expect(picker.pressedCount == 0)
  }

  @Test func reportsFailureWhenNeitherPathIsAvailable() {
    let picker = FakePicker(respondsToButtonPressed: false, rawPickerCanBePresented: false)

    let outcome = FeedbackBroadcastActivation.activate(
      picker: picker, preferredExtension: nil)

    #expect(outcome == .unavailable)
    #expect(picker.pressedCount == 0)
  }

  @Test func alwaysOffersTheMicrophoneToggleBecauseNarrationIsThePoint() {
    for respondsToButtonPressed in [true, false] {
      let picker = FakePicker(respondsToButtonPressed: respondsToButtonPressed)

      _ = FeedbackBroadcastActivation.activate(
        picker: picker, preferredExtension: "com.example.app.broadcast")

      #expect(picker.configuredMicrophoneButton == true)
      #expect(picker.configuredExtension == "com.example.app.broadcast")
    }
  }

  @Test func configuresThePickerBeforePressingIt() {
    // Order matters: pressing first would launch the picker with no
    // `preferredExtension` and no mic button, i.e. the wrong sheet.
    final class OrderRecordingPicker: BroadcastPicker {
      var respondsToButtonPressed = true
      private(set) var events: [String] = []
      func configure(preferredExtension: String?, showsMicrophoneButton: Bool) {
        events.append("configure")
      }
      func pressButton() { events.append("press") }
      func presentRawPicker() -> Bool {
        events.append("present")
        return true
      }
    }
    let picker = OrderRecordingPicker()

    _ = FeedbackBroadcastActivation.activate(
      picker: picker, preferredExtension: "com.example.app.broadcast")

    #expect(picker.events == ["configure", "press"])
  }
}
