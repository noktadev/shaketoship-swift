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

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color.red)
        .frame(width: 9, height: 9)
        .shadow(color: .red.opacity(0.6), radius: 3)
      Text("Recording feedback")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.primary)
      Spacer(minLength: 8)
      Text("Tap to stop")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(.ultraThinMaterial)
    .contentShape(Rectangle())
    .onTapGesture(perform: onStop)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Recording feedback, tap to stop")
    .accessibilityAddTraits(.isButton)
  }
}
#endif
