#if canImport(UIKit)
import AVKit
import SwiftUI

/// Identifies a finalized recording awaiting the user's Upload/Discard decision.
struct FeedbackReviewData: Identifiable {
  let id: String  // sessionId
  let movURL: URL
  let dir: URL
  let events: [FeedbackEvent]
  /// Optional context line shown above the buttons - used by the foreground
  /// resend offer (#472) to explain "your recording stopped when you left".
  let note: String?

  init(id: String, movURL: URL, dir: URL, events: [FeedbackEvent], note: String? = nil) {
    self.id = id
    self.movURL = movURL
    self.dir = dir
    self.events = events
    self.note = note
  }
}

/// Full-screen review shown after a recording stops (shake/cap/Live-Activity
/// stop). The user previews the clip and chooses Upload or Discard. Device-only
/// UI - NOT unit tested.
struct FeedbackReviewSheet: View {
  let data: FeedbackReviewData
  let onUpload: () -> Void
  let onDiscard: () -> Void

  /// True once Upload or Discard has fired. Disables both buttons: a second tap
  /// must never double-PUT the session or delete the dir during its upload.
  @State private var acted = false

  private let player: AVPlayer

  /// Screen events only: the strip is a navigation trail, and taps would swamp
  /// it. Taps still ship in events.json for the analysis agent.
  private var screenChips: [(t: Double, screen: String)] {
    data.events.compactMap { event in
      guard let screen = event.screen else { return nil }
      return (event.t, screen)
    }
  }

  init(
    data: FeedbackReviewData,
    onUpload: @escaping () -> Void,
    onDiscard: @escaping () -> Void
  ) {
    self.data = data
    self.onUpload = onUpload
    self.onDiscard = onDiscard
    self.player = AVPlayer(url: data.movURL)
  }

  var body: some View {
    VStack(spacing: 0) {
      VideoPlayer(player: player)
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .background(Color.black)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(Array(screenChips.enumerated()), id: \.offset) { _, chip in
            HStack(spacing: 4) {
              Text(String(format: "%.1fs", chip.t))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
              Text(chip.screen)
                .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
          }
        }
        .padding(.horizontal, 16)
      }
      .frame(height: 44)
      .padding(.top, 12)

      Text(data.id)
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
        .padding(.top, 8)

      if let note = data.note {
        Text(note)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .padding(.top, 10)
      }

      Spacer(minLength: 12)

      HStack(spacing: 12) {
        Button(role: .destructive) { act(onDiscard) } label: {
          Label("Discard", systemImage: "trash")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(acted)

        Button { act(onUpload) } label: {
          Label("Upload", systemImage: "arrow.up.circle.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(acted)
      }
      .padding(16)
    }
    .onAppear { player.play() }
    .onDisappear { player.pause() }
  }

  /// `disabled` alone is not enough: two taps in the same frame both dispatch
  /// before the re-render, so the flag is checked here too.
  private func act(_ action: () -> Void) {
    guard !acted else { return }
    acted = true
    action()
  }
}
#endif
