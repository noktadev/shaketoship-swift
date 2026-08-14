#if canImport(UIKit)
import SwiftUI

/// Slim persistent top-of-screen recording indicator (#474). Shown ONLY on
/// devices WITHOUT a Dynamic Island (island devices rely on the Live Activity as
/// the sole indicator). Lives in ShakeToShip so it is shared across apps, not
/// hand-rolled per app. Tapping it stops the recording (alongside shake-to-stop
/// and the Live Activity STOP button).
struct FeedbackRecordingBar: View {
  /// Whether the host's `Capabilities` ceiling grants the microphone at all.
  /// A host that never granted it has nothing for the user to mute, so the
  /// toggle (and the "Speak now" headline) only ever appear when this is true.
  let microphoneAllowed: Bool
  /// Invoked when the bar is tapped; the modifier routes it to a user stop.
  let onStop: () -> Void

  /// The user's persisted microphone floor - the same key `FeedbackRecorder`
  /// reads at start and live per-buffer. Muting here takes effect immediately;
  /// unmuting mid-recording cannot retro-add an audio input that was never
  /// armed, so it takes effect from the next recording (privacy-safe by
  /// construction, see `FeedbackMicrophonePreference`).
  @AppStorage(FeedbackMicrophonePreference.storageKey) private var muted = false

  @State private var pulsing = false

  /// True only when the microphone is actually being captured for THIS bar:
  /// the host granted it AND the user has not muted it. Drives the headline -
  /// `FeedbackRecordingCopy.activePrompt` ("Speak now") would be a lie in
  /// either of the other two states.
  private var microphoneLive: Bool { microphoneAllowed && !muted }

  /// Two different non-live strings, not one: the caption directly below the
  /// headline is always the literal "Feedback is recording", so reusing that
  /// exact sentence as the headline made the bar say the same thing twice
  /// (review round 1, finding 1). The two non-live states also mean
  /// different things to the user - "this app never had a mic" needs no
  /// mention of one at all, while "you muted it" is information the user who
  /// flipped the toggle specifically wants confirmed - so they get separate
  /// copy, not a shared fallback.
  private var headline: String {
    if microphoneLive { return FeedbackRecordingCopy.activePrompt }
    return microphoneAllowed ? Self.recordingMicMutedPrompt : Self.recordingScreenOnlyPrompt
  }

  private var stopAccessibilityLabel: String {
    if microphoneLive { return FeedbackRecordingCopy.activeAccessibilityLabel }
    return microphoneAllowed
      ? Self.recordingMicMutedAccessibilityLabel : Self.recordingScreenOnlyAccessibilityLabel
  }

  /// Private to this file: `FeedbackRecordingCopy.swift` is owned by a
  /// different chunk. Kept as short as `activePrompt` so `lineLimit(1)` +
  /// `minimumScaleFactor(0.8)` don't have to fight a longer string.
  private static let recordingScreenOnlyPrompt = "Recording your screen"
  private static let recordingScreenOnlyAccessibilityLabel =
    "Feedback is recording your screen. Tap to stop."
  private static let recordingMicMutedPrompt = "Recording, mic off"
  private static let recordingMicMutedAccessibilityLabel =
    "Feedback is recording. Microphone muted. Tap to stop."

  var body: some View {
    HStack(spacing: 10) {
      // The stop target. A real `Button` rather than the bar-wide
      // `.onTapGesture` this used to carry: a `Button` placed inside a view
      // that also owns `.onTapGesture` does not reliably win the touch in
      // SwiftUI, which would toggle mute AND stop the recording on one tap.
      // Splitting the stop affordance into its own `Button` (and doing the
      // same below for "Tap to stop") makes the mute button a genuine
      // sibling instead of a nested control, so there is nothing to race.
      Button(action: onStop) {
        HStack(spacing: 10) {
          recordingDot
          VStack(alignment: .leading, spacing: 1) {
            Text(headline)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            Text("Feedback is recording")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        // Stretched to the row's full height before shaping the hit area:
        // without this the tap target was only as tall as the dot/text
        // content, leaving the padding band above/below dead (review round
        // 1, finding 2). `maxWidth` is left alone - the leading cluster
        // keeps its intrinsic width so the mute button and trailing label
        // still get their own space.
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(stopAccessibilityLabel)

      if microphoneAllowed {
        Button {
          muted.toggle()
        } label: {
          Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
            .foregroundStyle(.secondary)
            // Width doubled to 44pt (review round 1, item 3): a privacy
            // control needs a real touch target even though the icon itself
            // stays small. Height stays at 22pt - the bar may not grow
            // taller than the halo it was already built around.
            .frame(width: 44, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // State in the label, effect in the hint (review round 1, item 5):
        // VoiceOver already announces "Button" for a real `Button`, so
        // folding "Double tap to..." into the label read the tap
        // instruction twice. The hint is where that phrasing belongs.
        .accessibilityLabel(muted ? "Microphone muted" : "Microphone on")
        .accessibilityHint(muted ? "Double tap to unmute" : "Double tap to mute")
      }

      // Second stop target, trailing-aligned in the leftover space (the old
      // `Spacer(minLength: 8)` between the text block and this label). Its own
      // `Button` for the same reason as above; hidden from the accessibility
      // tree so VoiceOver sees ONE stop element (the label above already
      // says "Tap to stop") and ONE mute element, not three.
      Button(action: onStop) {
        Text("Tap to stop")
          .font(.footnote)
          .foregroundStyle(.secondary)
          // maxHeight added alongside the existing maxWidth (review round 1,
          // finding 2): without it this label's hit area was only as tall as
          // the footnote text, leaving most of the row's right half dead.
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHidden(true)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial)
  }

  /// Solid core inside a pulsing halo. The halo carries the legibility (#357 -
  /// the flat 9pt dot read as noise on device) while the core stays small enough
  /// that the bar itself remains slim.
  private var recordingDot: some View {
    let halo = FeedbackRecordingBarMetrics.haloDiameter
    let core = FeedbackRecordingBarMetrics.coreDiameter
    return ZStack {
      Circle()
        .fill(Color.red.opacity(0.25))
        .frame(width: halo, height: halo)
        .scaleEffect(pulsing ? 1 : 0.6)
        .opacity(pulsing ? 0.35 : 0.9)
      Circle()
        .fill(Color.red)
        .frame(width: core, height: core)
        .shadow(color: .red.opacity(0.6), radius: 3)
    }
    .frame(width: halo, height: halo)
    .accessibilityHidden(true)
    .onAppear {
      withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
        pulsing = true
      }
    }
  }
}
#endif
