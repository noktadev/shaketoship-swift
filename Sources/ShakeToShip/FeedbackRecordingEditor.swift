#if canImport(UIKit)
import AVKit
import SwiftUI
import UIKit

@MainActor @Observable
final class FeedbackRecordingEditor {
  var source: URL?
  var player: AVPlayer?
  var poster: UIImage?
  var thumbnails: [UIImage] = []
  var playing = false
  var duration = 0.0
  var aspect = 1.0
  var range = FeedbackTrimRange(start: 0, end: 0) {
    didSet {
      // Edited text has no timestamps. A new trim must use the remaining timed speech.
      if range != oldValue { transcriptEdit = nil }
    }
  }
  var error: String?
  var loading = true
  var preparing = false
  var drawing = false
  let ink = FeedbackInkCanvas()
  var previewSize = CGSize.zero
  var context: FeedbackDevContext?
  var events: [FeedbackEvent] = []
  /// Playhead position in source seconds, driven by a periodic time observer.
  var currentTime = 0.0
  /// Nil until the tracks load. False means the saved file has no audio track.
  var hasAudio: Bool?
  /// Nil while unknown or unavailable; the review hides the transcript then.
  var transcript: [FeedbackTranscriptSegment]?
  var transcribing = false
  /// The user's edited transcript, valid only for the current trim range.
  var transcriptEdit: String?
  var transcriptRemoved = false
  let audio = FeedbackPreviewAudio()
  private var timeObserver: Any?
  private var transcriptionTask: Task<Void, Never>?
  private var generation = UUID()
  private var stopped = false

  /// Timed segments inside the trim window.
  var visibleTranscript: [FeedbackTranscriptSegment] {
    transcript.map { FeedbackTranscript.visible($0, in: range) } ?? []
  }

  /// What Send appends to the note, or nil when there is nothing to send.
  var transcriptForSend: String? {
    guard !transcriptRemoved else { return nil }
    let text = transcriptEdit ?? FeedbackTranscript.text(visibleTranscript)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func load(_ data: FeedbackComposerData,
    sourceResolver: @MainActor (FeedbackComposerData) async throws -> URL = { data in
      guard let recording = data.recorded else { throw FeedbackVideoRecoveryError.invalidMedia }
      return try await FeedbackRecordingEdit.source(in: data.dir, fallback: recording)
    }
  ) async {
    guard !stopped, !Task.isCancelled, source == nil, data.recorded != nil else { return }
    generation = UUID()
    let expected = generation
    loading = true
    error = nil
    defer { if isCurrent(expected) { loading = false } }
    do {
      let source = try await sourceResolver(data)
      guard isCurrent(expected) else { return }
      let duration = try await AVURLAsset(url: source).load(.duration).seconds
      guard isCurrent(expected) else { return }
      guard duration.isFinite, duration > 0 else { throw FeedbackVideoRecoveryError.invalidMedia }
      let videoTracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)
      guard isCurrent(expected) else { return }
      if let track = videoTracks.first {
        let size = try await track.load(.naturalSize)
        guard isCurrent(expected) else { return }
        let transform = try await track.load(.preferredTransform)
        guard isCurrent(expected) else { return }
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        aspect = abs(bounds.width / bounds.height)
      }
      self.duration = duration
      range = .init(start: 0, end: duration)
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 720, height: 1280)
      let first = try await generator.image(at: .zero)
      guard isCurrent(expected) else { return }
      poster = UIImage(cgImage: first.image)
      self.source = source
      let audioTracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
      guard isCurrent(expected) else { return }
      hasAudio = !audioTracks.isEmpty
      #if DEBUG
      print("[ShakeToShip] review source \(source.lastPathComponent): duration=\(duration)s audioTracks=\(audioTracks.count) microphonePlan=\(data.capabilities.contains(.microphone)) muted=\(FeedbackMicrophonePreference().isMuted)")
      #endif
      let player = AVPlayer(url: source)
      self.player = player
      timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
        MainActor.assumeIsolated {
          guard let self, self.isCurrent(expected) else { return }
          self.tick(time.seconds)
        }
      }
      if hasAudio == true, data.capabilities.contains(.microphone) { transcribe(source, generation: expected) }
      generator.maximumSize = CGSize(width: 100, height: 180)
      for index in 0..<8 {
        let frame = try? await generator.image(at: CMTime(seconds: duration * Double(index) / 8, preferredTimescale: 600))
        guard isCurrent(expected) else { return }
        thumbnails.append(UIImage(cgImage: frame?.image ?? first.image))
      }
      let saved = try? Data(contentsOf: FeedbackRecordingEdit.file("events.json", in: data.dir))
      let session = saved.flatMap { try? JSONDecoder().decode(FeedbackSession.self, from: $0) }
      events = session?.events ?? data.events
      context = session?.dev_context ?? .current(events: events)
    } catch {
      guard isCurrent(expected) else { return }
      self.error = "The recording could not be opened. Try again."
    }
  }

  private func isCurrent(_ expected: UUID) -> Bool {
    !stopped && !Task.isCancelled && generation == expected
  }

  private func tick(_ time: Double) {
    guard time.isFinite else { return }
    currentTime = time
    if playing, time >= range.end - 0.01 { pause() }
  }

  private func transcribe(_ source: URL, generation expected: UUID) {
    guard isCurrent(expected) else { return }
    transcribing = true
    let transcriber = FeedbackTranscription.transcriber
    // The narration language is the person's first preferred language, not the host UI language.
    let locale = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    transcriptionTask = Task { [weak self] in
      let audio = FileManager.default.temporaryDirectory.appendingPathComponent("sts-transcript-\(UUID().uuidString).m4a")
      defer { try? FileManager.default.removeItem(at: audio) }
      var segments: [FeedbackTranscriptSegment]?
      do {
        segments = try await FeedbackTranscription.transcribe(source: source, audio: audio,
          locale: locale, using: transcriber)
      } catch { segments = nil }
      guard let self, self.isCurrent(expected) else { return }
      self.transcribing = false
      self.transcript = segments?.isEmpty == false ? segments : nil
    }
  }

  func pause() {
    player?.pause()
    playing = false
    audio.end()
  }

  /// The sheet closed or Send started: no playback, no audio session, no background work.
  func stop() {
    stopped = true
    generation = UUID()
    loading = false
    pause()
    transcriptionTask?.cancel()
    transcriptionTask = nil
    transcribing = false
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    timeObserver = nil
  }

  func seek(_ time: Double) {
    pause()
    currentTime = time
    player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600)
  }

  func togglePlayback() {
    guard !stopped, let player else { return }
    if playing { pause(); return }
    let time = player.currentTime().seconds
    if time < range.start || time >= range.end - 0.05 { seek(range.start) }
    player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600)
    drawing = false
    audio.begin()
    player.play()
    playing = true
  }

  func prepare(_ data: FeedbackComposerData) async -> Bool {
    guard !stopped, !preparing, let source else { return false }
    preparing = true
    pause()
    defer { preparing = false }
    do {
      var annotation: CGImage?
      if !ink.strokes.isEmpty {
        guard previewSize.width > 0, previewSize.height > 0 else { throw FeedbackVideoRecoveryError.invalidMedia }
        let renderer = ImageRenderer(content: FeedbackReviewInk(strokes: ink.strokes)
          .frame(width: previewSize.width, height: previewSize.height))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw FeedbackVideoRecoveryError.invalidMedia }
        annotation = image
      }
      _ = try await FeedbackRecordingEdit.prepare(source: source, in: data.dir, range: range,
        context: context, events: events, annotation: annotation)
      return true
    } catch { self.error = "The recording could not be prepared. Try Send again."; return false }
  }
}

/// Persistent review marks use the same stroke model as the live cursor.
struct FeedbackReviewInk: View {
  let strokes: [[FeedbackInkPoint]]
  var body: some View {
    Canvas { context, _ in
      for stroke in strokes where stroke.count > 1 {
        var path = Path()
        path.addLines(stroke.map { CGPoint(x: $0.x, y: $0.y) })
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      }
    }.allowsHitTesting(false)
  }
}

/// A real poster remains underneath the player until AVFoundation has a frame to display.
private struct FeedbackVideoPreview: UIViewRepresentable {
  let player: AVPlayer
  let poster: UIImage?
  func makeUIView(context: Context) -> Preview { Preview() }
  func updateUIView(_ view: Preview, context: Context) {
    view.image.image = poster
    if view.video.player !== player { view.video.player = player }
  }
  final class Preview: UIView {
    let image = UIImageView()
    let video = AVPlayerLayer()
    private var observation: NSKeyValueObservation?
    override init(frame: CGRect) {
      super.init(frame: frame)
      image.contentMode = .scaleAspectFit
      addSubview(image)
      video.videoGravity = .resizeAspect
      video.opacity = 0
      layer.addSublayer(video)
      observation = video.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
        let ready = layer.isReadyForDisplay
        Task { @MainActor in self?.video.opacity = ready ? 1 : 0 }
      }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
      super.layoutSubviews()
      image.frame = bounds
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      video.frame = bounds
      CATransaction.commit()
    }
  }
}

struct FeedbackRecordingEditorView: View {
  @Bindable var editor: FeedbackRecordingEditor
  var onPreview: () -> Void
  @State private var marking = false
  @Environment(\.shakeToShipTheme) private var theme
  var body: some View {
    VStack(spacing: 20) {
      if let player = editor.player, editor.poster != nil {
        ZStack(alignment: .topTrailing) {
          FeedbackVideoPreview(player: player, poster: editor.poster)
            .overlay {
              GeometryReader { proxy in
                FeedbackReviewInk(strokes: editor.ink.strokes)
                  .onAppear { editor.previewSize = proxy.size }
                  .onChange(of: proxy.size) { _, size in editor.previewSize = size }
                if editor.drawing {
                  Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                      if !marking { editor.ink.beginStroke(); marking = true }
                      editor.ink.append(x: value.location.x, y: value.location.y, at: 0)
                    }.onEnded { _ in marking = false })
                }
              }
            }
            .frame(width: min(300, 268 * editor.aspect), height: min(268, 300 / editor.aspect))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .accessibilityIdentifier("ShakeToShip.review.video")
          VStack {
            HStack(spacing: 0) {
              Spacer(minLength: 0)
              Button {
                editor.drawing.toggle()
                editor.pause()
              } label: { Image(systemName: "pencil.tip") }
                .foregroundStyle(editor.drawing ? theme.accent ?? .accentColor : theme.primaryText ?? .primary)
                .accessibilityLabel("Markup").accessibilityValue(editor.drawing ? "On" : "Off")
            }
            Spacer(minLength: 0)
            HStack {
              if !editor.ink.strokes.isEmpty {
                Button { editor.ink.clear() } label: { Image(systemName: "eraser") }
                  .accessibilityLabel("Clear marks")
              }
              Spacer(minLength: 0)
              Button { editor.pause(); onPreview() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
              }
                .accessibilityLabel("Preview recording").accessibilityIdentifier("ShakeToShip.review.preview")
            }
          }.padding(2).font(.system(size: 14, weight: .medium)).buttonStyle(FeedbackPreviewActionStyle())
        }.frame(width: min(300, 268 * editor.aspect), height: min(268, 300 / editor.aspect))
          .frame(maxWidth: .infinity)
        FeedbackTrimScrubber(editor: editor)
        if editor.hasAudio == false {
          // Evidence on the device: the saved file itself has no sound.
          Label("No sound in this recording", systemImage: "speaker.slash")
            .feedbackFont(.footnote, inherit: false).foregroundStyle(theme.secondaryText ?? .secondary)
            .frame(maxWidth: .infinity).accessibilityIdentifier("ShakeToShip.review.noAudio")
        }
      } else if editor.loading {
        ProgressView("Opening recording…").frame(height: 268).frame(maxWidth: .infinity)
      }
      if let error = editor.error { Text(error).foregroundStyle(.red).font(.footnote) }
    }
    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
      if let item = notification.object as? AVPlayerItem, item === editor.player?.currentItem { editor.pause() }
    }
  }
}

private struct FeedbackPreviewActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.frame(width: 28, height: 28)
      .background(.regularMaterial, in: Circle())
      .frame(width: 44, height: 44).contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.5 : 1)
  }
}

/// One filmstrip, with two independently adjustable handles. Each handle also supports VoiceOver.
struct FeedbackTrimScrubber: View {
  @Bindable var editor: FeedbackRecordingEditor
  @Environment(\.shakeToShipTheme) private var theme
  private var accent: Color { theme.accent ?? .accentColor }
  var body: some View {
    HStack(spacing: 12) {
      Button { editor.togglePlayback() } label: {
        VStack(spacing: 2) {
          Image(systemName: editor.playing ? "pause.fill" : "play.fill").font(.title3)
          Text(FeedbackTrimScrubber.clock(editor.currentTime))
            .font(.system(size: 11, weight: .medium, design: .monospaced)).monospacedDigit()
            .foregroundStyle(theme.secondaryText ?? .secondary).fixedSize()
            .accessibilityIdentifier("ShakeToShip.review.time")
        }.frame(width: 44, height: 52)
          .contentShape(Rectangle())
          .foregroundStyle(theme.primaryText ?? .primary)
      }.buttonStyle(.plain).accessibilityLabel(editor.playing ? "Pause preview" : "Play preview")
        .accessibilityValue(FeedbackTrimScrubber.clock(editor.currentTime))
      GeometryReader { proxy in
        let width = max(1, proxy.size.width - 24)
        let start = width * editor.range.start / max(editor.duration, 0.1)
        let end = width * editor.range.end / max(editor.duration, 0.1)
        ZStack(alignment: .leading) {
          HStack(spacing: 1) {
            ForEach(Array(editor.thumbnails.enumerated()), id: \.offset) { _, thumbnail in
              Image(uiImage: thumbnail).resizable().scaledToFill()
                .frame(width: max(1, proxy.size.width / 8), height: 44).clipped()
            }
          }.frame(width: proxy.size.width, height: 44).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
              HStack(spacing: 0) {
                Color.black.opacity(0.4).frame(width: start)
                Color.clear.frame(width: end - start + 24)
                Color.black.opacity(0.4)
              }.allowsHitTesting(false)
            }
            .accessibilityHidden(true)
            // Tap or drag on the strip scrubs. The playhead stays inside the trim window.
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
              let time = (value.location.x - 12) / width * editor.duration
              editor.seek(min(editor.range.end, max(editor.range.start, time)))
            })
          RoundedRectangle(cornerRadius: 6).strokeBorder(accent, lineWidth: 3)
            .frame(width: max(24, end - start + 24), height: 52).offset(x: start)
            .allowsHitTesting(false)
          Capsule().fill(.white).frame(width: 3, height: 56)
            .shadow(color: .black.opacity(0.35), radius: 1.5)
            .offset(x: 12 + width * min(max(editor.currentTime, 0), editor.duration) / max(editor.duration, 0.1) - 1.5)
            .allowsHitTesting(false).accessibilityHidden(true)
            .accessibilityIdentifier("ShakeToShip.review.playhead")
          handle(start: true, width: width).offset(x: start - 16)
          handle(start: false, width: width).offset(x: end + 8 - 16)
        }.frame(height: 52).coordinateSpace(name: "feedback-filmstrip")
      }.frame(height: 52)
    }
    .accessibilityElement(children: .contain)
  }
  private func handle(start: Bool, width: Double) -> some View {
    RoundedRectangle(cornerRadius: 5).fill(accent).frame(width: 12, height: 52)
      .overlay(Capsule().fill(.white).frame(width: 3, height: 20))
      .frame(width: 44, height: 52).contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("feedback-filmstrip")).onChanged { value in
        // Translation starts at the current handle; capture its time only at touch-down.
        if dragStart == nil { dragStart = start ? editor.range.start : editor.range.end }
        update((dragStart ?? 0) + value.translation.width / width * editor.duration, start: start)
      }.onEnded { _ in dragStart = nil })
      .accessibilityElement().accessibilityLabel(start ? "Trim start" : "Trim end")
      .accessibilityValue(time(start ? editor.range.start : editor.range.end))
      .accessibilityIdentifier(start ? "ShakeToShip.trim.start" : "ShakeToShip.trim.end")
      .accessibilityAdjustableAction { direction in
        let step = max(0.1, editor.duration / 20)
        let current = start ? editor.range.start : editor.range.end
        update(current + (direction == .increment ? step : -step), start: start)
      }
  }
  @State private var dragStart: Double?
  private func update(_ value: Double, start: Bool) {
    let gap = min(0.1, editor.duration / 2)
    if start { editor.range.start = max(0, min(value, editor.range.end - gap)) }
    else { editor.range.end = min(editor.duration, max(value, editor.range.start + gap)) }
    editor.seek(start ? editor.range.start : editor.range.end)
  }
  private func time(_ value: Double) -> String { String(format: "%.1f seconds", value) }
  static func clock(_ value: Double) -> String {
    let seconds = max(0, Int(value.isFinite ? value : 0))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

/// On-device transcript under the preview: three lines until Show all, the phrase at the
/// playhead highlighted, and a tap on a phrase seeks the video. Never blocks Send.
struct FeedbackTranscriptView: View {
  @Bindable var editor: FeedbackRecordingEditor
  @State private var expanded = false
  @State private var editing = false
  @FocusState private var focused: Bool
  @Environment(\.shakeToShipTheme) private var theme
  private var accent: Color { theme.accent ?? .accentColor }
  private var secondary: Color { theme.secondaryText ?? .secondary }

  var body: some View {
    if editor.transcriptRemoved {
      EmptyView()
    } else if editor.transcribing {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Transcribing…").feedbackFont(.footnote, inherit: false).foregroundStyle(secondary)
      }.accessibilityElement(children: .combine).accessibilityIdentifier("ShakeToShip.review.transcribing")
    } else if editor.transcript != nil {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Transcript").feedbackFont(.footnote.weight(.semibold), inherit: false).foregroundStyle(secondary)
          Spacer(minLength: 8)
          if editing {
            Button("Done") { editing = false; focused = false }.feedbackFont(.footnote, inherit: false)
              .frame(minHeight: 44)
          } else {
            Menu {
              Button("Edit transcript", systemImage: "pencil") {
                if editor.transcriptEdit == nil { editor.transcriptEdit = FeedbackTranscript.text(editor.visibleTranscript) }
                editing = true; focused = true
              }
              Button("Remove transcript", systemImage: "trash", role: .destructive) { editor.transcriptRemoved = true }
            } label: {
              Image(systemName: "ellipsis").frame(width: 44, height: 32).contentShape(Rectangle())
            }.foregroundStyle(secondary).accessibilityLabel("Transcript options")
              .accessibilityIdentifier("ShakeToShip.review.transcriptMenu")
          }
        }
        if editing || editor.transcriptEdit != nil {
          TextField("Transcript", text: Binding(get: { editor.transcriptEdit ?? "" }, set: { editor.transcriptEdit = $0 }),
            axis: .vertical)
            .lineLimit(editing ? 2...8 : 1...3).textFieldStyle(.plain).focused($focused)
            .feedbackFont(.subheadline, inherit: false).foregroundStyle(theme.primaryText ?? .primary)
            .disabled(!editing)
        } else {
          let segments = editor.visibleTranscript
          Text(attributed(segments))
            .feedbackFont(.subheadline, inherit: false).foregroundStyle(theme.primaryText ?? .primary)
            .tint(theme.primaryText ?? .primary)
            .lineLimit(expanded ? nil : 3)
            .environment(\.openURL, OpenURLAction { url in
              guard url.scheme == "sts-transcript", let index = Int(url.host() ?? ""),
                let segment = segments.first(where: { $0.id == index }) else { return .discarded }
              editor.seek(max(editor.range.start, segment.start))
              return .handled
            })
            .accessibilityIdentifier("ShakeToShip.review.transcript")
          if FeedbackTranscript.text(segments).count > 140 {
            Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
              .feedbackFont(.footnote.weight(.semibold), inherit: false).foregroundStyle(accent)
              .frame(minHeight: 32)
          }
        }
      }
      .onChange(of: editor.range) { _, _ in editing = false; focused = false }
    }
  }

  private func attributed(_ segments: [FeedbackTranscriptSegment]) -> AttributedString {
    let current = FeedbackTranscript.current(segments, at: editor.currentTime)?.id
    var text = AttributedString()
    for (offset, segment) in segments.enumerated() {
      var part = AttributedString(segment.text)
      part.link = URL(string: "sts-transcript://\(segment.id)")
      if segment.id == current {
        part.backgroundColor = accent.opacity(0.22)
      }
      text += part
      if offset < segments.count - 1 { text += AttributedString(" ") }
    }
    return text
  }
}

struct FeedbackDevContextCard: View {
  let context: FeedbackDevContext
  @Environment(\.shakeToShipTheme) private var theme
  @Environment(\.dynamicTypeSize) private var typeSize
  private var storage: String {
    context.storageFreeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable"
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      let layout = typeSize >= .xxxLarge ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
      layout {
        stat("iphone", context.os, context.device)
        stat("internaldrive", storage, "Storage free")
        stat("battery.50percent", context.batteryPercent.map { "\($0)%" } ?? "—", context.lowPower ? "Low power" : "Battery")
      }
      VStack(spacing: 16) {
        row("App", "\(context.appVersion) (\(context.build))")
        row("Locale", context.locale)
        row("Screen", "\(context.screenWidth) × \(context.screenHeight) pt")
        row("Screen trail", String(context.screenCount))
        row("Taps captured", String(context.tapCount))
        row("Low power", context.lowPower ? "On" : "Off")
      }
    }.accessibilityIdentifier("ShakeToShip.review.context")
  }
  private func stat(_ symbol: String, _ value: String, _ caption: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(systemName: symbol).font(.body).foregroundStyle(theme.secondaryText ?? .secondary)
      Text(value).feedbackFont(.subheadline.weight(.semibold), inherit: false).lineLimit(2)
      Text(caption).feedbackFont(.caption, inherit: false).foregroundStyle(theme.secondaryText ?? .secondary).lineLimit(2)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      .background(theme.surface ?? Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
      .accessibilityElement(children: .combine)
  }
  private func row(_ label: String, _ value: String) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(theme.secondaryText ?? .secondary); Spacer(minLength: 24); Text(value) }
      VStack(alignment: .leading, spacing: 4) { Text(label).foregroundStyle(theme.secondaryText ?? .secondary); Text(value) }
    }.feedbackFont(.subheadline, inherit: false).textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
  }
}
#endif
