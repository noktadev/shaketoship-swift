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
  /// The capsule keeps the timer, microphone level, and Stop visible. Its
  /// leading edge anchors the ink as the user drags it across the host.
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
    var microphoneLevel: @Sendable () -> Double = { FeedbackMicrophoneLevel.shared.current }
    let onStop: () -> Void
    let onTogglePause: () -> Void
    /// The shared annotation state. The pill writes strokes here; the layer in
    /// the captured host window renders them (#1391).
    let ink: FeedbackInkCanvas
    /// Reports the cursor's hit box, in window coordinates, whenever it moves or
    /// resizes. The pass-through window claims exactly this region and declines
    /// everything else (#1391), so it has to be told where the cursor is.
    var onInteractiveFrame: (CGRect) -> Void = { _ in }

    @State private var nib: CGPoint?
    /// Finger-to-nib offset captured at touch-down, so grabbing the label does
    /// not teleport the nib under the fingertip.
    @State private var grab: CGSize = .zero
    @State private var dragging = false
    @State private var expanded = false
    @State private var measured: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Same binding the bar used: `FeedbackMicrophonePreference.isMuted` is
    /// read-only on purpose, and `@AppStorage` keeps the toggle reactive if the
    /// host's Settings row changes it mid-recording.
    @AppStorage(FeedbackMicrophonePreference.storageKey) private var muted = false

    var body: some View {
      GeometryReader { geo in
        let safe = geo.safeAreaInsets
        let point = FeedbackCursorGeometry.clamp(nib ?? FeedbackCursorGeometry.home(in: geo.size),
          in: geo.size, safeTop: safe.top, safeBottom: safe.bottom, measured: measured)
        let box = FeedbackCursorGeometry.hitBox(nib: point, measured: measured)

        ZStack(alignment: .topLeading) {
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
                    ink.beginStroke()
                  }
                  let moved = CGPoint(
                    x: value.location.x - grab.width, y: value.location.y - grab.height)
                  let clamped = FeedbackCursorGeometry.clamp(
                    moved, in: geo.size, safeTop: safe.top, safeBottom: safe.bottom, measured: measured)
                  nib = clamped
                  // The pill's window and the host window are both full-screen in
                  // the same scene, so a point is the same point in either.
                  ink.append(
                    x: clamped.x, y: clamped.y, at: Date().timeIntervalSinceReferenceDate)
                }
                .onEnded { _ in
                  dragging = false
                  ink.endStroke(now: Date().timeIntervalSinceReferenceDate)
                })
            .onTapGesture(count: 2) {
              withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { expanded.toggle() }
            }
            .onLongPressGesture {
              withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)) { expanded.toggle() }
            }
        }
        // Two consumers need the box, so it is published on first layout and
        // after every drag and every expansion (#1391): the window hosting this
        // view claims only this region and passes every other touch to the app
        // below, and the ink layer uses it to tell a grab of the pill from a tap
        // on the app.
        .onAppear { publish(box) }
        .onChange(of: box) { _, new in publish(new) }
        // A touch on the app retires the ink AND closes the expanded row, as it
        // always did. The touch is observed by the ink layer now, so the count
        // is how the pill hears about it.
        .onChange(of: ink.retirements) { _, _ in
          guard expanded else { return }
          withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.86)) { expanded = false }
        }
      }
      .ignoresSafeArea()

    }

    private var shape: some Shape {
      Capsule()
    }

    private var label: some View {
      HStack(spacing: 12) {
        microphoneMeter
        if paused {
          Text(FeedbackRecordingCopy.pausedLabel)
            .font(.subheadline.monospaced()).fontWeight(.medium).foregroundStyle(recordingRed)
        } else {
          // CLOCK RULE: read the tick off `timeline.date`. A `Date()` in here is
          // a second clock and skews phase against the ink canvas.
          TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
            Text(FeedbackCursorClock.elapsed(from: startedAt, to: timeline.date))
              .font(.system(.title3, design: .monospaced, weight: .medium)).foregroundStyle(recordingRed)
          }
        }
        Button(action: onStop) {
          RoundedRectangle(cornerRadius: 5).fill(recordingRed).frame(width: 20, height: 20)
            .frame(width: 44, height: 44)
            .overlay(Circle().strokeBorder(recordingRed.opacity(0.45), lineWidth: 2))
        }.buttonStyle(.plain).accessibilityLabel(FeedbackRecordingCopy.stopAction)
        if expanded {
          Divider().frame(height: 18)
          action(
            paused ? "play.fill" : "pause.fill", .white,
            paused ? FeedbackRecordingCopy.resumeAction : FeedbackRecordingCopy.pauseAction,
            onTogglePause)
          // The bar this replaces carried a mid-recording mute. Dropping a
          // privacy control silently is not on, so it moves here - and only
          // appears when the host actually granted `.microphone`.
          if microphoneAllowed {
            action(
              muted ? "mic.slash.fill" : "mic.fill", .white,
              muted ? FeedbackRecordingCopy.unmuteAction : FeedbackRecordingCopy.muteAction
            ) {
              muted.toggle()
            }
          }
        }
      }
      .padding(.leading, 20).padding(.trailing, 10)
      .padding(.vertical, 10)
      .background(Color(white: 0.09), in: shape)
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

    private var microphoneMeter: some View {
      TimelineView(.periodic(from: .now, by: 0.1)) { _ in
        let level = microphoneAllowed && !muted && !paused ? microphoneLevel() : 0
        HStack(spacing: 2) {
          ForEach(0..<16) { index in
            Capsule().fill(recordingRed.opacity(index < 10 ? 1 : 0.35))
              .frame(width: 2, height: index < 10 ? 3 + level * Double(26 - abs(index - 4) * 4) : 3)
          }
        }.frame(width: 62, height: 28)
      }.accessibilityLabel(muted || !microphoneAllowed ? "Microphone off" : "Microphone level")
    }

    // Recording uses a semantic red on charcoal in every host theme.
    private var recordingRed: Color { Color(uiColor: .systemPink) }

    /// Icon-only so the expansion stays one slim row. The icon is the
    /// affordance; the accessible name comes from the label, never the glyph.
    private func action(
      _ icon: String, _ tint: Color, _ name: String, _ act: @escaping () -> Void
    ) -> some View {
      Button(action: act) {
        Image(systemName: icon)
          .font(.caption2)
          .foregroundStyle(tint)
          .frame(width: 44, height: 44)
          .background(tint.opacity(0.12), in: Circle())
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(name)
    }

    /// Tells both consumers where the pill is: the window that decides which
    /// touches it claims, and the ink layer that decides which touches retire
    /// the ink.
    private func publish(_ box: CGRect) {
      ink.cursorBox = box
      onInteractiveFrame(box)
    }
  }
#endif
