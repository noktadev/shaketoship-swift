#if canImport(UIKit)
import SwiftUI

/// Slim persistent top-of-screen recording indicator (#474). Shown ONLY on
/// devices WITHOUT a Dynamic Island (island devices rely on the Live Activity as
/// the sole indicator). Lives in AppFeedback so it is shared across apps, not
/// hand-rolled per app. Tapping it stops the recording (alongside shake-to-stop
/// and the Live Activity STOP button).
struct FeedbackRecordingBar: View {
  /// Invoked when the bar is tapped; the modifier routes it to a user stop.
  let onStop: () -> Void

  @State private var pulsing = false

  var body: some View {
    HStack(spacing: 10) {
      recordingDot
      VStack(alignment: .leading, spacing: 1) {
        Text(FeedbackRecordingCopy.activePrompt)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text("Feedback is recording")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text("Tap to stop")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial)
    .contentShape(Rectangle())
    .onTapGesture(perform: onStop)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(FeedbackRecordingCopy.activeAccessibilityLabel)
    .accessibilityAddTraits(.isButton)
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
