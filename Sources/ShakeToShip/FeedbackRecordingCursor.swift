#if canImport(UIKit)
  import SwiftUI
  import UIKit

  /// The recording indicator, and the annotation pen, and the transport - one
  /// draggable cursor.
  ///
  /// Replaces `FeedbackRecordingBar`, a full-width strip pinned to the top. The
  /// bar had two problems a person hit immediately on TestFlight: its greedy hit
  /// areas made `.ultraThinMaterial` blanket the entire screen so the app was
  /// unusable mid-recording (#1183), and once slimmed it sat behind the clock and
  /// battery (#1184). A small thing you can move solves both by construction -
  /// it can never cover the app, and it can never be stuck somewhere unreachable.
  ///
  /// Shape is a FigJam-style cursor: three rounded corners and one sharp. The
  /// sharp corner is the nib, it sits exactly on the drag point, and ink is
  /// emitted from it - so a stroke reads as drawn BY the cursor rather than
  /// trailing out of the middle of a label.
  ///
  /// Motion budget is deliberately small. This view is composited INTO the
  /// recording, so every looping animation is re-encoded into the artifact a
  /// reviewer watches and pulls the eye off whatever is being demonstrated. One
  /// low-amplitude status pulse, springs under 300ms, nothing else.
  @MainActor
  struct FeedbackRecordingCursor: View {
    let microphoneAllowed: Bool
    let paused: Bool
    let startedAt: Date
    let onStop: () -> Void
    let onTogglePause: () -> Void

    @State private var nib: CGPoint?
    /// Finger-to-nib offset captured at touch-down, so grabbing the label does
    /// not teleport the nib under the fingertip.
    @State private var grab: CGSize = .zero
    @State private var dragging = false
    @State private var expanded = false
    @State private var strokes: [[FeedbackInkPoint]] = []
    @State private var dismissedAt: TimeInterval?
    @State private var measured: CGSize = .zero
    @State private var pulsing = false
    /// Same binding the bar used: `FeedbackMicrophonePreference.isMuted` is
    /// read-only on purpose, and `@AppStorage` keeps the toggle reactive if the
    /// host's Settings row changes it mid-recording.
    @AppStorage(FeedbackMicrophonePreference.storageKey) private var muted = false

    var body: some View {
      GeometryReader { geo in
        let safe = geo.safeAreaInsets
        let point = nib ?? FeedbackCursorGeometry.home(in: geo.size)

        ZStack(alignment: .topLeading) {
          FeedbackInkTrail(strokes: strokes, dismissedAt: dismissedAt)

          // Observes touch-downs WITHOUT consuming them, so a tap on the app
          // both retires the ink and still reaches the app. Same mechanism the
          // tap trail already uses; nothing new intercepts touches here.
          FeedbackWindowTouchObserver { location in
            guard
              !FeedbackCursorGeometry.hitBox(nib: point, measured: measured).contains(location),
              !strokes.isEmpty, dismissedAt == nil
            else { return }
            dismissedAt = Date().timeIntervalSinceReferenceDate
            if expanded { withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { expanded = false } }
          }
          .frame(width: 0, height: 0)

          label
            .offset(x: point.x, y: point.y)
            // minimumDistance must stay above 0: at 0 the drag swallows the tap
            // and the expansion can never open.
            .gesture(
              DragGesture(minimumDistance: 3)
                .onChanged { value in
                  if !dragging {
                    grab = CGSize(
                      width: value.startLocation.x - point.x,
                      height: value.startLocation.y - point.y)
                    dragging = true
                    dismissedAt = nil
                  }
                  let moved = CGPoint(
                    x: value.location.x - grab.width, y: value.location.y - grab.height)
                  let clamped = FeedbackCursorGeometry.clamp(
                    moved, in: geo.size, safeTop: safe.top, safeBottom: safe.bottom)
                  nib = clamped
                  append(clamped)
                }
                .onEnded { _ in
                  dragging = false
                  strokes.append([])
                  strokes = FeedbackInkBuffer.pruned(
                    strokes, now: Date().timeIntervalSinceReferenceDate)
                })
            .onTapGesture(count: 2) {
              withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { expanded.toggle() }
            }
        }
      }
      .ignoresSafeArea()
      .onAppear {
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulsing = true }
      }
    }

    private var shape: some Shape {
      UnevenRoundedRectangle(
        topLeadingRadius: 1.5, bottomLeadingRadius: 14,
        bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous)
    }

    private var label: some View {
      HStack(spacing: 7) {
        statusDot
        if paused {
          Text(FeedbackRecordingCopy.pausedLabel)
            .font(.caption2.monospacedDigit()).fontWeight(.medium).foregroundStyle(.orange)
        } else {
          // CLOCK RULE: read the tick off `timeline.date`. A `Date()` in here is
          // a second clock and skews phase against the ink canvas.
          TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
            Text(FeedbackCursorClock.elapsed(from: startedAt, to: timeline.date))
              .font(.caption2.monospacedDigit()).fontWeight(.medium)
          }
        }
        if expanded {
          Divider().frame(height: 18)
          action(
            paused ? "play.fill" : "pause.fill", .orange,
            paused ? FeedbackRecordingCopy.resumeAction : FeedbackRecordingCopy.pauseAction,
            onTogglePause)
          action("stop.fill", .red, FeedbackRecordingCopy.stopAction, onStop)
          // The bar this replaces carried a mid-recording mute. Dropping a
          // privacy control silently is not on, so it moves here - and only
          // appears when the host actually granted `.microphone`.
          if microphoneAllowed {
            action(
              muted ? "mic.slash.fill" : "mic.fill", .secondary,
              muted ? FeedbackRecordingCopy.unmuteAction : FeedbackRecordingCopy.muteAction
            ) {
              muted.toggle()
            }
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.ultraThinMaterial, in: shape)
      .overlay(shape.stroke(.red.opacity(0.35), lineWidth: 1))
      .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
      .contentShape(shape)
      .background(
        GeometryReader { proxy in
          Color.clear
            .onAppear { measured = proxy.size }
            .onChange(of: proxy.size) { _, new in measured = new }
        })
      .accessibilityElement(children: .contain)
      .accessibilityLabel(
        paused ? FeedbackRecordingCopy.pausedLabel : FeedbackRecordingCopy.activePrompt)
    }

    private var statusDot: some View {
      ZStack {
        Circle()
          .fill(.red.opacity(paused ? 0 : 0.25))
          .frame(
            width: FeedbackRecordingBarMetrics.haloDiameter - 7,
            height: FeedbackRecordingBarMetrics.haloDiameter - 7)
          .scaleEffect(pulsing && !paused ? 1 : 0.7)
          .opacity(pulsing && !paused ? 0.35 : 0.9)
        if paused {
          Circle().strokeBorder(.orange, lineWidth: 2)
            .frame(
              width: FeedbackRecordingBarMetrics.coreDiameter - 6,
              height: FeedbackRecordingBarMetrics.coreDiameter - 6)
        } else {
          Circle().fill(.red)
            .frame(
              width: FeedbackRecordingBarMetrics.coreDiameter - 6,
              height: FeedbackRecordingBarMetrics.coreDiameter - 6)
        }
      }
      .accessibilityHidden(true)
    }

    /// Icon-only so the expansion stays one slim row. The icon is the
    /// affordance; the accessible name comes from the label, never the glyph.
    private func action(
      _ icon: String, _ tint: Color, _ name: String, _ act: @escaping () -> Void
    ) -> some View {
      Button(action: act) {
        Image(systemName: icon)
          .font(.caption2)
          .foregroundStyle(tint)
          .frame(width: 30, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(name)
    }

    private func append(_ point: CGPoint) {
      let ink = FeedbackInkPoint(
        x: point.x, y: point.y, t: Date().timeIntervalSinceReferenceDate)
      if strokes.isEmpty {
        strokes = [[ink]]
      } else {
        strokes[strokes.count - 1].append(ink)
      }
    }
  }
#endif
