#if canImport(UIKit)
import SwiftUI

/// Transient "shake again to stop" hint (#1092), shown the moment a
/// recording starts. Styled like `FeedbackToast` (ultraThinMaterial capsule,
/// footnote text) so it reads as part of the same recording-in-progress UI.
/// Non-blocking by construction: no buttons, and the caller marks it
/// `.allowsHitTesting(false)` so taps always pass through to the app below.
/// The modifier owns the auto-dismiss timer and the stop-clears rule
/// (`FeedbackShakeHintGate`) - this view only renders the current state.
struct FeedbackShakeStopHint: View {
  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "iphone.gen3.radiowaves.left.and.right")
        .foregroundStyle(.secondary)
      Text(FeedbackRecordingCopy.shakeAgainToStopHint)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.ultraThinMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    .transition(.opacity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(FeedbackRecordingCopy.shakeAgainToStopAccessibilityLabel)
  }
}
#endif
