import Foundation
import Observation

/// App-process bridge from a non-shake entry point (Settings' "Send feedback
/// now" row) into `ShakeRecorderModifier`'s existing shake-handling path.
/// Registering here and calling through `handleShake()` guarantees the manual
/// entry point observes the exact same cooldown/rate-cap/busy suppression a
/// physical shake does (see `FeedbackPromptGate`) - there is no separate,
/// divergent "start recording" code path to keep in sync.
@MainActor
public enum FeedbackManualTrigger {
  @Observable final class Availability {
    var recording = false
  }
  private static let availability = Availability()
  static var reportRecording: FeedbackReportRecording?
  /// SwiftUI tracks this read and updates mounted cards when the handler changes.
  public static var isRecordingAvailable: Bool { availability.recording }

  private static var recordingPreparation: (@MainActor () -> Void)?
  private static var recordingGate: (@MainActor () -> Bool)?
  private static var recordingHandler: (@MainActor () -> Void)?
  private static var handler: (@MainActor () -> Void)?

  /// The modifier registers this while mounted (recorder active at all).
  static func register(_ handler: @escaping @MainActor () -> Void,
    recording: (@MainActor () -> Void)? = nil,
    prepareRecording: (@MainActor () -> Void)? = nil,
    onRecordingRequestedWhileGated: (@MainActor () -> Bool)? = nil) {
    self.handler = handler
    self.recordingHandler = recording
    self.recordingPreparation = prepareRecording
    self.recordingGate = onRecordingRequestedWhileGated
    availability.recording = recording != nil
  }

  /// The modifier unregisters on teardown so a stale closure cannot fire.
  static func unregister() {
    handler = nil
    recordingHandler = nil
    recordingGate = nil
    recordingPreparation = nil
    availability.recording = false
  }

  /// Called by the manual entry point (e.g. a Settings row). No-op when
  /// nothing is mounted (recorder inert - App Store, or gate off).
  /// Explicit walkthrough entry still uses the modifier's gate and recording consent.
  static func prepareRecording() { recordingPreparation?() }
  public static func signalRecording() {
    guard recordingHandler != nil, recordingGate?() != true else { return }
    recordingHandler?()
  }

  public static func signal() {
    handler?()
  }
}
