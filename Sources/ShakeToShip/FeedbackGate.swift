import Foundation

/// Pure runtime-gate decisions for the feedback recorder. Kept dependency-free
/// and UIKit-free so the "provably inert when off" and "don't nag" rules are
/// unit-tested without a live responder chain or recorder, exactly like
/// `FeedbackTapFormatting`.
public enum FeedbackGate {
  /// Whether `.shakeToShip(config:)` installs the recorder at all. A nil
  /// config is the inertness proof: no shake responder, no review window, no
  /// recorder is ever constructed. The per-app resolver decides the config is
  /// nil unless (DEBUG) or (remoteFlag && rolloutBucket && settingsOptIn).
  ///
  /// An empty `capabilities` ceiling is inert the same way: a host that
  /// grants nothing gets no responder either, so there is one inertness rule,
  /// not two.
  public static func shouldAttach(config: ShakeToShipConfig?) -> Bool {
    guard let config else { return false }
    return !config.capabilities.isEmpty
  }
}

/// What a capture session is allowed to do, once the host's capability
/// ceiling and the user's microphone floor are both resolved.
/// `startsScreenCapture == false` is refused by `FeedbackRecorder` before any
/// ReplayKit call is made, so an absent capability removes the code path
/// rather than only the button.
public struct FeedbackCapturePlan: Equatable, Sendable {
  /// Whether starting a ReplayKit capture is permitted at all.
  public let startsScreenCapture: Bool
  /// The one bit that drives BOTH the asset writer's audio input and
  /// `RPScreenRecorder.isMicrophoneEnabled`, so the two can never disagree
  /// about whether the microphone is live.
  public let capturesMicrophone: Bool

  /// Internal, not public: outside this module a plan can only come from
  /// `FeedbackGate.capturePlan(for:microphoneMuted:)` or `.inert`, so there is
  /// no way to mint a microphone-enabled plan that bypasses the `Capabilities`
  /// ceiling.
  init(startsScreenCapture: Bool, capturesMicrophone: Bool) {
    self.startsScreenCapture = startsScreenCapture
    self.capturesMicrophone = capturesMicrophone
  }

  /// The plan for a config that permits nothing: no capture, no microphone.
  public static let inert = FeedbackCapturePlan(startsScreenCapture: false, capturesMicrophone: false)
}

extension FeedbackGate {
  /// Resolves the host's capability ceiling and the user's microphone floor
  /// into one plan. `transcription` never reaches this decision - it is a
  /// server-side storage request, not a capture bit (rule 3), so flipping it
  /// changes no field here. The flag IS carried on `ShakeToShipConfig`, but is
  /// not yet transmitted to the collector, so today it has no effect either way.
  public static func capturePlan(
    for config: ShakeToShipConfig, microphoneMuted: Bool = false
  ) -> FeedbackCapturePlan {
    FeedbackCapturePlan(
      startsScreenCapture: config.capabilities.contains(.screenRecording),
      capturesMicrophone: config.capabilities.contains(.microphone) && !microphoneMuted)
  }

  /// Re-resolves the microphone floor for ONE segment of an already-planned
  /// recording. `FeedbackRecordingSession` reuses one recorder across several
  /// `start(to:)` calls (pause/resume across app background/foreground), so
  /// the plan stored at recorder init can go stale: it must never be replayed
  /// as-is into a later segment.
  ///
  /// `capturesMicrophone` is ANDed with `!microphoneMuted`, never ORed. Two
  /// properties follow and both matter. First, muting between segments
  /// narrows the very next segment immediately. Second, unmuting between
  /// segments can NEVER re-arm a recording that started muted: once the
  /// stored plan's bit is false, AND cannot raise it back. That second
  /// property is the documented asymmetry of this SDK: unmuting takes effect
  /// from the next RECORDING, not the next segment, and that is the
  /// privacy-safe direction.
  static func planForSegment(_ plan: FeedbackCapturePlan, microphoneMuted: Bool) -> FeedbackCapturePlan {
    FeedbackCapturePlan(
      startsScreenCapture: plan.startsScreenCapture,
      capturesMicrophone: plan.capturesMicrophone && !microphoneMuted)
  }
}

/// The end user's persisted microphone floor - independent of the host's
/// `Capabilities` ceiling, and lower than it: even a host that grants
/// `.microphone` records no audio once the user mutes it here. Backed by
/// injected `UserDefaults` rather than a singleton or actor, so tests prove
/// "persists per install" by reading it back through a second instance built
/// on the same suite, the way a relaunched app would.
public struct FeedbackMicrophonePreference {
  /// Shared by the recorder's read and the review bar's `@AppStorage` toggle.
  public static let storageKey = "shaketoship.microphone.muted"

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Unmuted by default - a fresh install has no floor below the host's
  /// `Capabilities` ceiling until the user chooses one.
  public var isMuted: Bool {
    defaults.bool(forKey: Self.storageKey)
  }

  /// Internal, not public: only the SDK's own control (the recording bar's
  /// `@AppStorage` toggle) writes the floor. A host app may READ it via
  /// `isMuted` or bind its own settings row to `storageKey`, but must never
  /// overwrite the end user's choice, including forcing an unmute.
  func setMuted(_ muted: Bool) {
    defaults.set(muted, forKey: Self.storageKey)
  }
}

/// What an idle/active shake should do, once suppression is accounted for.
public enum FeedbackShakeAction: Equatable {
  /// Suppressed - busy, mid-review, past the rate cap, or inside the cooldown.
  case ignore
  /// Already recording: a shake stops it.
  case stopRecording
  /// Idle and allowed: surface the "Something wrong?" prompt.
  case showPrompt
}

/// Decides whether a shake surfaces the prompt. The cooldown stops a
/// walking-with-phone nag loop after a "Not now"; the rate cap goes silent
/// after `maxPromptsPerSession` dismissals until the next launch.
public enum FeedbackPromptGate {
  /// After a "Not now", ignore shakes for this long.
  public static let cooldownSeconds: TimeInterval = 60
  /// Max prompts surfaced per app session; silent afterwards.
  public static let maxPromptsPerSession = 3

  /// - Parameters:
  ///   - now / lastDismissedAt: seconds on any monotonic-ish clock; only their
  ///     difference matters, so the caller can pass `Date().timeIntervalSince1970`
  ///     or `ProcessInfo.systemUptime` as long as it is consistent.
  public static func action(
    isRecording: Bool,
    busy: Bool,
    reviewPresenting: Bool,
    promptPresenting: Bool,
    promptsShown: Int,
    lastDismissedAt: TimeInterval?,
    now: TimeInterval
  ) -> FeedbackShakeAction {
    if isRecording { return .stopRecording }
    // A shake while the prompt is already up must not re-count or re-emit -
    // otherwise a couple of shakes burn the whole per-session cap instantly.
    if busy || reviewPresenting || promptPresenting { return .ignore }
    if promptsShown >= maxPromptsPerSession { return .ignore }
    if let lastDismissedAt, now - lastDismissedAt < cooldownSeconds { return .ignore }
    return .showPrompt
  }
}
