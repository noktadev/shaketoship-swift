import Foundation

/// Where a shake lands, once the host's capability ceiling is resolved.
enum FeedbackShakeDestination: Equatable, Sendable {
  /// Ask first: this host can record, so the "Something wrong?" prompt offers
  /// Record or Write.
  case prompt
  /// Nothing to ask about - this host cannot record, so the shake opens the
  /// composer directly rather than adding a tap that only ever means "Write".
  case composer
  /// Neither a recording nor a composer entry exists. A shake does nothing.
  case none
}

/// One picked item's journey onto disk: where it is now, and the name chunk H
/// uploads it under.
struct FeedbackAttachmentWrite: Equatable, Sendable {
  let source: URL
  let fileName: String
}

/// Every rule the composer obeys, as pure functions.
///
/// The sheet itself stays device-only UI - it was never unit tested and still
/// is not - so the send-enabled rule, the item cap and the capability gating of
/// each affordance live here, where `swift test` runs them with no UIKit, no
/// photo library and no device. That is the same split `FeedbackGate` and
/// `FeedbackTapFormatting` already use.
enum FeedbackComposerRules {
  /// Send is disabled until there is media OR a non-blank note. The SDK never
  /// sends an empty report.
  static func sendEnabled(media: [FeedbackMediaItem], note: String) -> Bool {
    !media.isEmpty || !trimmed(note).isEmpty
  }

  /// No Attach button without `.photoLibrary` - and none once the basket is
  /// full, because the cap is on the composer's media, not on one picker
  /// session (the recorded clip already holds a slot).
  static func showsAttach(capabilities: Capabilities, mediaCount: Int) -> Bool {
    capabilities.contains(.photoLibrary) && mediaCount < FeedbackAttachmentBounds.maxItems
  }

  /// No note field without `.text`.
  static func showsNoteField(capabilities: Capabilities) -> Bool {
    capabilities.contains(.text)
  }

  /// No Record action without `.screenRecording` or when ReplayKit is not
  /// available. Device availability can only narrow the host's capability
  /// ceiling. The default keeps existing non-device callers source compatible.
  static func showsRecordAction(
    capabilities: Capabilities, recordingAvailable: Bool = true
  ) -> Bool {
    capabilities.contains(.screenRecording) && recordingAvailable
  }

  /// Whether an item may be taken back out of the strip.
  ///
  /// Only a picked one may. The recorded clip is already `recording.mov` in
  /// the session dir and is named by `events.json`'s segments: dropping it
  /// from the strip would remove the thumbnail and upload the video anyway,
  /// which is worse than not offering the affordance. Discard drops the whole
  /// report, which is how a recording is unsent.
  static func showsRemove(for item: FeedbackMediaItem) -> Bool {
    !item.isRecorded
  }

  /// The picker only ever offers the slots that are still free, so a selection
  /// can never overshoot the cap and be trimmed after the user made it.
  static func remainingSelectionLimit(mediaCount: Int) -> Int {
    max(0, FeedbackAttachmentBounds.maxItems - mediaCount)
  }

  /// A host that cannot record must not be asked "Record & report", and a host
  /// with nothing to compose must not be shown an empty composer that can
  /// never send.
  static func shakeDestination(
    capabilities: Capabilities, recordingAvailable: Bool = true
  ) -> FeedbackShakeDestination {
    if showsRecordAction(
      capabilities: capabilities, recordingAvailable: recordingAvailable
    ) {
      return .prompt
    }
    if capabilities.contains(.text) || capabilities.contains(.photoLibrary) { return .composer }
    return .none
  }

  /// The hub entry order. Recording first where a recording can start now,
  /// with the text form as the secondary "Write it instead" when the host
  /// collects text. Elsewhere the form keeps its "Report a bug" row, so no
  /// Record button is dead and no Write action opens a form without a text field.
  static func hubEntryActions(
    capabilities: Capabilities, recordingAvailable: Bool, hub: HubOptions
  ) -> [FeedbackHubEntryAction] {
    (showsRecordAction(capabilities: capabilities, recordingAvailable: recordingAvailable)
      ? [.record, showsNoteField(capabilities: capabilities) ? .write : .report] : [.report])
      + (hub.contains(.ideas) ? [.suggest, .ideas] : [])
      + (hub.contains(.inbox) ? [.inbox] : [])
  }

  /// The consent card's secondary action, named for what the composer collects.
  /// Nil when the composer has nothing to collect.
  static func writeEntryTitle(capabilities: Capabilities) -> String? {
    if showsNoteField(capabilities: capabilities) { return FeedbackHubEntryAction.write.title }
    if showsAttach(capabilities: capabilities, mediaCount: 0) { return "Add an attachment instead" }
    return nil
  }

  /// Picked items numbered from zero in composer order. The recorded clip is
  /// skipped: it is already `recording.mov` in the session dir and is never
  /// re-written as an attachment.
  static func attachmentPlan(media: [FeedbackMediaItem]) -> [FeedbackAttachmentWrite] {
    media.filter { !$0.isRecorded }.enumerated().map { index, item in
      FeedbackAttachmentWrite(
        source: item.url,
        fileName: FeedbackAttachmentNaming.attachmentFile(index: index, kind: item.kind))
    }
  }

  /// What `note.txt` should contain, or nil when there is no note to write.
  /// Trimmed: trailing whitespace the user never sees must not become a file
  /// that reads as content to the analysis agent.
  static func noteFileContents(note: String) -> String? {
    let text = trimmed(note)
    return text.isEmpty ? nil : text
  }

  private static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// What the composer hands back on Send.
struct FeedbackComposerResult: Sendable, Equatable {
  let media: [FeedbackMediaItem]
  let note: String

  init(media: [FeedbackMediaItem], note: String) {
    self.media = media
    self.note = note
  }

  /// The recorded path: the clip plus one optional note. The model writes the title.
  static func recorded(_ recording: URL, note: String) -> FeedbackComposerResult {
    FeedbackComposerResult(media: [.recorded(recording)], note: note)
  }
}

/// The post-capture card's note, kept as `note.txt` in the unconfirmed capture
/// directory while the user types. Nothing uploads without `.confirmed`, Send
/// rewrites the file through `persistComposedReport`, and Discard removes the
/// directory, so a dismissal or background interruption keeps the note for the
/// recovery offer.
enum FeedbackRecordedNoteDraft {
  @discardableResult
  static func save(_ note: String, in dir: URL) -> Bool {
    let url = dir.appendingPathComponent(FeedbackAttachmentNaming.noteFile)
    do {
      if let contents = FeedbackComposerRules.noteFileContents(note: note) {
        try Data(contents.utf8).write(to: url, options: .atomic)
      } else if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      return true
    } catch { return false }
  }

  static func load(in dir: URL) -> String {
    (try? String(contentsOf: dir.appendingPathComponent(FeedbackAttachmentNaming.noteFile), encoding: .utf8)) ?? ""
  }
}

/// One row or action on the hub entry, in `FeedbackComposerRules.hubEntryActions` order.
enum FeedbackHubEntryAction: Equatable, Sendable {
  case record, write, report, suggest, ideas, inbox

  var title: String {
    switch self {
    case .record: "Record a walkthrough"
    case .write: "Write it instead"
    case .report: "Report a bug"
    case .suggest: "Suggest an idea"
    case .ideas: "Ideas"
    case .inbox: "Inbox"
    }
  }
}

/// Materializes a composed report into its session dir: the picked items under
/// their `attachment-N` names and, when non-blank, `note.txt`. The recorded
/// clip is already in place and is not touched.
///
/// Returns false if any write failed, so the caller can surface it rather than
/// uploading a report that silently lost the user's note. Kept out of the
/// `canImport(UIKit)` block on purpose: the files it produces are the seam
/// chunk H uploads across, and a test proves the names ON DISK, not in a plan.
@discardableResult
func persistComposedReport(_ result: FeedbackComposerResult, in dir: URL) -> Bool {
  var ok = true
  let plan = FeedbackComposerRules.attachmentPlan(media: result.media)
  let selected = Set(plan.map(\.fileName))
  // A partial save can leave files from the previous selection. Remove only
  // composer-owned evidence, never recordings, identity bindings, or markers.
  for index in 0..<FeedbackAttachmentBounds.maxItems {
    for kind in [FeedbackMediaKind.image, .video] {
      let name = FeedbackAttachmentNaming.attachmentFile(index: index, kind: kind)
      let obsolete = dir.appendingPathComponent(name)
      if !selected.contains(name), FileManager.default.fileExists(atPath: obsolete.path) {
        do { try FileManager.default.removeItem(at: obsolete) } catch { ok = false }
      }
    }
  }
  for write in plan {
    let destination = dir.appendingPathComponent(write.fileName)
    do {
      // A retried send (upload failed, user sends again) would otherwise throw
      // on an existing file and lose the attachment.
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: write.source, to: destination)
    } catch {
      ok = false
    }
  }
  if let contents = FeedbackComposerRules.noteFileContents(note: result.note) {
    do {
      try Data(contents.utf8).write(
        to: dir.appendingPathComponent(FeedbackAttachmentNaming.noteFile), options: .atomic)
    } catch {
      ok = false
    }
  } else {
    let note = dir.appendingPathComponent(FeedbackAttachmentNaming.noteFile)
    if FileManager.default.fileExists(atPath: note.path) {
      do { try FileManager.default.removeItem(at: note) } catch { ok = false }
    }
  }
  return ok
}

#if canImport(UIKit)
import AVKit
import SwiftUI
import UIKit

/// The same preference as the recording cursor; changing it does not edit the saved clip.
struct FeedbackMicrophoneRow: View {
  @Environment(\.shakeToShipTheme) private var theme
  @Environment(\.locale) private var locale
  @AppStorage(FeedbackMicrophonePreference.storageKey) private var muted = false
  var body: some View {
    Toggle(isOn: Binding(get: { !muted }, set: { muted = !$0 })) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Feedback microphone", bundle: .module).feedbackFont(.body).feedbackPrimaryText()
        Text("Applies to your next recording.", bundle: .module)
          .feedbackFont(.caption).foregroundStyle(.secondary)
      }
    }
    .environment(\.locale, theme.locale ?? locale)
    .accessibilityIdentifier("ShakeToShip.review.microphone")
    .feedbackTheme()
  }
}

/// Everything the composer needs to open. One composer, many fillers: it is
/// the single destination for every entry point - shake then Record or Write,
/// a bare `FeedbackManualTrigger.signal()` with no recording, and the
/// interrupted-session offer with the partial clip already in the slot.
struct FeedbackComposerData: Identifiable {
  let id: String  // sessionId
  let dir: URL
  let events: [FeedbackEvent]
  /// The session's finalized screen capture, when there is one. Nil for every
  /// entry point that starts with no recording.
  let recorded: URL?
  /// Optional context line shown above the buttons - used by the foreground
  /// resend offer (#472) to explain "your recording stopped when you left".
  /// Distinct from the user's own note, which the composer collects.
  let contextNote: String?
  /// The host's ceiling. Drives which affordances exist at all.
  let capabilities: Capabilities
  /// Bounds an attached video, per `ShakeToShipConfig.maxAttachmentDuration`.
  let maxAttachmentDuration: TimeInterval
  let notePrompt: String
  let sendLabel: String
  let showsTrail: Bool
  let initialMedia: [FeedbackMediaItem]
  let titlePrompt: String?
  let initialTitle: String
  let initialNote: String

  init(
    id: String,
    dir: URL,
    events: [FeedbackEvent],
    recorded: URL? = nil,
    contextNote: String? = nil,
    capabilities: Capabilities = .all,
    notePrompt: String = "What happened?",
    sendLabel: String = "Send",
    showsTrail: Bool = true,
    initialMedia: [FeedbackMediaItem] = [],
    titlePrompt: String? = nil,
    initialTitle: String = "",
    initialNote: String = "",
    maxAttachmentDuration: TimeInterval = ShakeToShipConfig.defaultMaxDuration
  ) {
    self.id = id
    self.dir = dir
    self.events = events
    self.recorded = recorded
    self.contextNote = contextNote
    self.capabilities = capabilities
    self.maxAttachmentDuration = maxAttachmentDuration
    self.notePrompt = notePrompt
    self.sendLabel = sendLabel
    self.showsTrail = showsTrail
    self.initialMedia = initialMedia
    self.titlePrompt = titlePrompt
    self.initialTitle = initialTitle
    self.initialNote = initialNote
  }

  /// The same capture with a note the review card already collected.
  func withInitialNote(_ note: String) -> FeedbackComposerData {
    FeedbackComposerData(id: id, dir: dir, events: events, recorded: recorded, contextNote: contextNote,
      capabilities: capabilities, notePrompt: notePrompt, sendLabel: sendLabel, showsTrail: showsTrail,
      initialMedia: initialMedia, titlePrompt: titlePrompt, initialTitle: initialTitle, initialNote: note,
      maxAttachmentDuration: maxAttachmentDuration)
  }

  /// Where picked items are staged before Send copies them to their
  /// `attachment-N` names. Inside the session dir, so Discard's single
  /// `removeItem(at: dir)` takes the staged copies with it.
  var stagingDirectory: URL {
    dir.appendingPathComponent("staging", isDirectory: true)
  }
}

/// The composer. Full-screen, presented in its own overlay window
/// (`FeedbackReviewWindowPresenter`). Device-only UI - NOT unit tested; every
/// rule it obeys is in `FeedbackComposerRules`, which is.
struct FeedbackComposer: View {
  let data: FeedbackComposerData
  let onSend: (FeedbackComposerResult) -> Void
  let onDiscard: () -> Void
  /// nil -> not rendered. See `ShakeToShipConfig.onOptOut`.
  let onOptOut: (() -> Void)?
  let actionReset: UUID?
  let inheritsHostStyle: Bool
  let formHeader: AnyView?
  let formFooter: AnyView?
  let onDraftChange: ((FeedbackComposerDraftValue) throws -> Void)?
  let onRecord: ((FeedbackComposerDraftValue) throws -> Void)?
  @State private var selectedAttachment: FeedbackMediaItem?
  @Environment(\.shakeToShipTheme) private var theme

  /// 0 to 3 items, in the order the user built them. Seeded with the recorded
  /// clip when the entry point had one.
  @State private var media: [FeedbackMediaItem]
  @State private var title = ""
  @State private var note = ""
  /// Running total of the picked bytes, so the byte cap is enforced across a
  /// whole basket rather than per picker session.
  @State private var pickedBytes = 0
  /// Inline rejection copy under the strip; nil = nothing to say.
  @State private var rejectionMessage: String?
  @State private var showPicker = false

  /// True once Send or Discard has fired. Disables both: a second tap must
  /// never double-PUT the session or delete the dir during its upload.
  @State private var acted = false

  private let player: AVPlayer?

  /// Screen events only: the strip is a navigation trail, and taps would swamp
  /// it. Taps still ship in events.json for the analysis agent.
  private var screenChips: [(t: Double, screen: String)] {
    data.events.compactMap { event in
      guard let screen = event.screen else { return nil }
      return (event.t, screen)
    }
  }

  private var sendEnabled: Bool {
    FeedbackComposerRules.sendEnabled(media: media, note: composedNote)
  }

  init(
    data: FeedbackComposerData,
    onSend: @escaping (FeedbackComposerResult) -> Void,
    onDiscard: @escaping () -> Void,
    onOptOut: (() -> Void)? = nil,
    actionReset: UUID? = nil,
    inheritsHostStyle: Bool = false,
    formHeader: AnyView? = nil,
    formFooter: AnyView? = nil,
    onDraftChange: ((FeedbackComposerDraftValue) throws -> Void)? = nil,
    onRecord: ((FeedbackComposerDraftValue) throws -> Void)? = nil
  ) {
    self.data = data
    self.onSend = onSend
    self.onDiscard = onDiscard
    self.onOptOut = onOptOut
    self.actionReset = actionReset
    self.inheritsHostStyle = inheritsHostStyle
    self.formHeader = formHeader
    self.formFooter = formFooter
    self.onDraftChange = onDraftChange
    self.onRecord = onRecord
    _title = State(initialValue: data.initialTitle)
    _note = State(initialValue: data.initialNote)
    _media = State(initialValue: (data.recorded.map { [.recorded($0)] } ?? []) + data.initialMedia)
    _pickedBytes = State(initialValue: data.initialMedia.filter { !$0.isRecorded }.reduce(0) { total, item in
      total + ((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    })
    self.player = data.recorded.map { AVPlayer(url: $0) }
  }

  var body: some View {
    Group {
      if inheritsHostStyle { nativeRows } else { legacyContent }
    }
    .onChange(of: actionReset) { _, _ in acted = false }
    .onAppear { player?.play() }
    .onDisappear { player?.pause() }
    .onChange(of: title) { _, _ in saveDraft() }
    .onChange(of: note) { _, _ in saveDraft() }
    .onChange(of: media) { _, _ in saveDraft() }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in saveDraft() }
    .fullScreenCover(item: $selectedAttachment) { item in
      FeedbackAttachmentViewer(items: media, initialSelection: item.url,
        onRemove: onDraftChange == nil ? nil : { remove($0) })
    }
    .sheet(isPresented: $showPicker) {
      FeedbackPhotoPicker(
        selectionLimit: FeedbackComposerRules.remainingSelectionLimit(mediaCount: media.count),
        stagingDirectory: data.stagingDirectory,
        maxAttachmentDuration: data.maxAttachmentDuration,
        existingCount: media.count, existingBytes: pickedBytes, onFinish: absorb
      ).ignoresSafeArea()
    }
  }

  private var draftValue: FeedbackComposerDraftValue {
    FeedbackComposerDraftValue(title: title, note: note, media: media)
  }
  private var canRecord: Bool {
    onRecord != nil && data.capabilities.contains(.screenRecording) && FeedbackManualTrigger.isRecordingAvailable
  }
  private func saveDraft() {
    guard !acted else { return }
    do { try onDraftChange?(draftValue) }
    catch { rejectionMessage = "Could not save your report. Please try again." }
  }
  private func recordDraft() {
    guard !acted, canRecord, media.count < FeedbackAttachmentBounds.maxItems else { return }
    acted = true
    do { try onRecord?(draftValue) }
    catch { acted = false; rejectionMessage = "Could not save your report. Please try again." }
  }

  private var composedNote: String {
    [title.trimmingCharacters(in: .whitespacesAndNewlines), note]
      .filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  private var nativeRows: some View {
    Form {
      formHeader
      if canRecord {
        Section {
          FeedbackWalkthroughButton(action: recordDraft)
            .disabled(acted || media.count >= FeedbackAttachmentBounds.maxItems)
        }.feedbackRow()
      }
      if let titlePrompt = data.titlePrompt, FeedbackComposerRules.showsNoteField(capabilities: data.capabilities) {
        Section("Title") { TextField(titlePrompt, text: $title).feedbackPrimaryText() }.feedbackRow()
      }
      if FeedbackComposerRules.showsNoteField(capabilities: data.capabilities) {
        Section {
          noteInput
        } header: {
          Text("Description")
        } footer: {
          if let contextNote = data.contextNote { Text(contextNote) }
        }.feedbackRow()
      }
      if !media.isEmpty || FeedbackComposerRules.showsAttach(
        capabilities: data.capabilities, mediaCount: media.count) || canRecord
      {
        Section("Attachments") {
          ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
              ForEach(media) { item in
                Button { selectedAttachment = item } label: {
                  FeedbackMediaThumbnail(item: item).frame(width: 96, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.borderless)
                  .accessibilityLabel(item.kind == .video ? "Video attachment" : "Image attachment")
                  .accessibilityIdentifier("ShakeToShip.attachment.thumbnail.\(item.kind.rawValue)")
                  .overlay(alignment: .topTrailing) {
                    if onDraftChange != nil || FeedbackComposerRules.showsRemove(for: item) {
                      Button { remove(item) } label: {
                        Image(systemName: "xmark.circle.fill")
                          .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                          .frame(width: 44, height: 44)
                      }.buttonStyle(.borderless).accessibilityLabel("Remove attachment")
                    }
                  }
              }
              if FeedbackComposerRules.showsAttach(
                capabilities: data.capabilities, mediaCount: media.count)
              {
                Button { showPicker = true } label: {
                  Image(systemName: "plus").font(.title2)
                    .frame(width: 96, height: 108)
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.borderless).accessibilityLabel("Attach a photo or video")
              }
              if canRecord {
                Button(action: recordDraft) {
                  VStack(spacing: 8) {
                    Image(systemName: "record.circle").font(.title2)
                    Text("Record").font(.body)
                  }.frame(width: 96, height: 108)
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.borderless)
                  .disabled(acted || media.count >= FeedbackAttachmentBounds.maxItems)
                  .accessibilityIdentifier("ShakeToShip.report.recordTile")
              }
            }
          }.scrollIndicators(.hidden)
        }.feedbackRow()
      }
      if data.recorded != nil {
        Section { FeedbackMicrophoneRow() }.feedbackRow()
      }
      formFooter
      if let rejectionMessage { Section { Text(rejectionMessage) }.feedbackRow() }
      Section {
        Button("Discard", role: .destructive) { act { onDiscard() } }.disabled(acted)
        if let onOptOut { Button("Stop sending feedback", role: .destructive) { act(onOptOut) } }
      }.feedbackRow()
    }
    .feedbackListStyle()
    .interactiveDismissDisabled(!title.isEmpty || !note.isEmpty || !media.isEmpty)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Send") { act { onSend(FeedbackComposerResult(media: media, note: composedNote)) } }
          .accessibilityLabel(data.sendLabel)
          .disabled(acted || !sendEnabled)
      }
    }
  }

  private var legacyContent: some View {
    VStack(spacing: 0) {
      preview
      mediaStrip
      if data.recorded != nil { FeedbackMicrophoneRow().padding(.horizontal, 16) }
      if let rejectionMessage {
        Text(rejectionMessage)
          .feedbackFont(.caption, inherit: inheritsHostStyle)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .padding(.top, 6)
      }
      if data.showsTrail { trail }
      if FeedbackComposerRules.showsNoteField(capabilities: data.capabilities) {
        noteField
      }
      if let contextNote = data.contextNote {
        Text(contextNote)
          .feedbackFont(.footnote, inherit: inheritsHostStyle)
          .foregroundStyle(inheritsHostStyle ? theme.secondaryText ?? .secondary : .secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .padding(.top, 10)
      }

      Spacer(minLength: 12)
      actions
    }
  }

  /// The large preview. A recorded clip keeps the player the review sheet
  /// always had; otherwise the first item stands in, and a composer with no
  /// media at all shows nothing and gives the space to the note.
  @ViewBuilder private var preview: some View {
    if let player, media.contains(where: \.isRecorded) {
      VideoPlayer(player: player)
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .background(Color.black)
    } else if let first = media.first {
      FeedbackMediaThumbnail(item: first)
        .frame(maxWidth: .infinity)
        .frame(height: 380)
        .background(Color.black)
    }
  }

  /// The strip earns its space only when it says something the big preview
  /// does not: a second item, or an Attach tile. A recording-only report on a
  /// host without `.photoLibrary` therefore looks exactly like the review
  /// sheet always did.
  private var stripVisible: Bool {
    FeedbackComposerRules.showsAttach(capabilities: data.capabilities, mediaCount: media.count)
      || media.count > 1
  }

  /// Thumbnails plus the Attach tile. Picked items carry a remove button; the
  /// recorded clip does not (see `remove`).
  @ViewBuilder private var mediaStrip: some View {
    if stripVisible { strip }
  }

  private var strip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(media) { item in
          ZStack(alignment: .topTrailing) {
            FeedbackMediaThumbnail(item: item)
              .frame(width: 64, height: 64)
              .clipShape(
                RoundedRectangle(cornerRadius: inheritsHostStyle ? theme.cornerRadius ?? 0 : 8))
            if FeedbackComposerRules.showsRemove(for: item) {
              Button {
                remove(item)
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .feedbackFont(.footnote, inherit: inheritsHostStyle)
                  .symbolRenderingMode(.palette)
                  .foregroundStyle(.white, .black.opacity(0.6))
                  .padding(3)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Remove attachment")
            }
          }
        }
        if FeedbackComposerRules.showsAttach(
          capabilities: data.capabilities, mediaCount: media.count)
        {
          Button {
            rejectionMessage = nil
            showPicker = true
          } label: {
            VStack(spacing: 2) {
              Image(systemName: "photo.badge.plus")
              Text("Attach").feedbackFont(.caption2, inherit: inheritsHostStyle)
            }
            .foregroundStyle(inheritsHostStyle ? theme.primaryText ?? .primary : .primary)
            .frame(width: 64, height: 64)
            .background(
              inheritsHostStyle && theme.surface != nil
                ? AnyShapeStyle(theme.surface!) : AnyShapeStyle(.ultraThinMaterial),
              in: RoundedRectangle(cornerRadius: inheritsHostStyle ? theme.cornerRadius ?? 0 : 8))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Attach a photo or video")
        }
      }
      .padding(.horizontal, 16)
    }
    .frame(height: 72)
    .padding(.top, 12)
  }

  /// The screen-trail chips and the session id, in their existing positions.
  private var trail: some View {
    VStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(Array(screenChips.enumerated()), id: \.offset) { _, chip in
            HStack(spacing: 4) {
              Text(String(format: "%.1fs", chip.t))
                .feedbackFont(.caption2.monospacedDigit(), inherit: inheritsHostStyle)
                .foregroundStyle(
                  inheritsHostStyle ? theme.secondaryText ?? .secondary : .secondary)
              Text(chip.screen)
                .feedbackFont(.caption2.weight(.medium), inherit: inheritsHostStyle)
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
        .feedbackFont(.caption2.monospaced(), inherit: inheritsHostStyle)
        .foregroundStyle(.tertiary)
        .padding(.top, 8)
    }
  }

  private var noteInput: some View {
    TextField(data.notePrompt, text: $note, axis: .vertical)
        .lineLimit(3...8)
      .foregroundStyle(inheritsHostStyle ? theme.primaryText ?? .primary : .primary)
      .accessibilityLabel("Note")
  }
  private var noteField: some View {
    Group {
      if inheritsHostStyle {
        if let radius = theme.cornerRadius {
          noteInput.textFieldStyle(.plain).padding(10)
            .background(
              theme.surface ?? Color(uiColor: .secondarySystemBackground),
              in: RoundedRectangle(cornerRadius: radius))
        } else if let surface = theme.surface {
          noteInput.textFieldStyle(.plain).padding(10).background(surface)
        } else {
          noteInput.textFieldStyle(.roundedBorder)
        }
      } else {
        noteInput.textFieldStyle(.plain).padding(10)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
  }

  /// Discard, Send and the optional opt-out keep their present positions and
  /// roles; only the primary action's name changed, because it now sends a
  /// report that may carry no recording at all.
  private var actions: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Button(role: .destructive) {
          act { onDiscard() }
        } label: {
          Label("Discard", systemImage: "trash")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(acted)

        if inheritsHostStyle {
          sendButton.buttonStyle(.bordered)
        } else {
          sendButton.buttonStyle(.borderedProminent)
            .tint(FeedbackPromptButtonColors.fillColor)
            .foregroundStyle(FeedbackPromptButtonColors.labelColor)
        }

      }
      .padding(.horizontal, 16)
      .padding(.top, 16)

      if let onOptOut {
        // Deliberately below and quieter than Discard/Send: this is not a
        // decision about THIS report, it is a decision about the feature.
        Button(role: .destructive) {
          act { onOptOut() }
        } label: {
          Text("Stop sending feedback")
            .feedbackFont(.footnote, inherit: inheritsHostStyle)
        }
        .buttonStyle(.plain)
        .disabled(acted)
        .padding(.top, 12)
        .padding(.bottom, 16)
      } else {
        Color.clear.frame(height: 16)
      }
    }
  }

  private var sendButton: some View {
    Button {
      act { onSend(FeedbackComposerResult(media: media, note: composedNote)) }
    } label: {
      Label(data.sendLabel, systemImage: "arrow.up.circle.fill")
        .frame(maxWidth: .infinity)
    }.disabled(acted || !sendEnabled)
  }

  /// Absorbs a finished picker session: admitted items join the strip, the
  /// first rejection is shown inline. Closing the sheet is this side's job -
  /// `PHPickerViewController` reports the selection but a SwiftUI `.sheet`
  /// stays up until its binding is cleared.
  private func absorb(_ outcome: FeedbackPhotoPickerOutcome) {
    showPicker = false
    let updated = media + outcome.accepted
    do {
      try onDraftChange?(FeedbackComposerDraftValue(title: title, note: note, media: updated))
    } catch {
      rejectionMessage = "Could not save your attachments. Please try again."
      return
    }
    media = updated
    pickedBytes += outcome.acceptedBytes
    rejectionMessage = outcome.rejection?.message
  }

  /// Only a picked item can leave the strip. The recorded clip is the
  /// session's own capture, already finalized as `recording.mov` and named by
  /// `events.json`'s segments - removing it from the strip alone would leave
  /// the file on disk and upload it anyway, which is worse than not offering
  /// the affordance. Discard drops the whole report, which is how a user
  /// unsends a recording today.
  @discardableResult
  private func remove(_ item: FeedbackMediaItem) -> Bool {
    guard onDraftChange != nil || FeedbackComposerRules.showsRemove(for: item) else { return false }
    let updated = media.filter { $0.id != item.id }
    do {
      try onDraftChange?(FeedbackComposerDraftValue(title: title, note: note, media: updated))
    } catch {
      rejectionMessage = "Could not remove this attachment. Please try again."
      return false
    }
    media = updated
    rejectionMessage = nil
    // The staged copy is inside the session dir, so Discard would take it
    // anyway - but a removed item must stop counting against the byte cap.
    if !item.isRecorded { pickedBytes = max(0, pickedBytes - (fileSize(item.url) ?? 0)) }
    try? FileManager.default.removeItem(at: item.url)
    return true
  }

  private func fileSize(_ url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
  }

  /// `disabled` alone is not enough: two taps in the same frame both dispatch
  /// before the re-render, so the flag is checked here too.
  private func act(_ action: () -> Void) {
    guard !acted else { return }
    acted = true
    action()
  }
}

/// A media tile. Images render themselves; a video renders a poster frame when
/// one can be made cheaply, and its film glyph otherwise. Never blocks the main
/// thread on a decode: this sheet appears the instant a recording stops.
struct FeedbackMediaThumbnail: View {
  let item: FeedbackMediaItem

  @State private var image: UIImage?

  var body: some View {
    ZStack {
      Color.black
      if let image {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: item.kind == .video ? "film" : "photo")
          .foregroundStyle(.white.opacity(0.7))
      }
    }
    .overlay {
      if item.kind == .video {
        Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white)
          .shadow(radius: 3).accessibilityHidden(true)
      }
    }
    .task(id: item.id) { image = await FeedbackMediaThumbnailLoader.load(item) }
    .accessibilityLabel(item.kind == .video ? "Video attachment" : "Image attachment")
  }
}

enum FeedbackMediaThumbnailLoader {
  static func load(_ item: FeedbackMediaItem) async -> UIImage? {
    let url = item.url
    let kind = item.kind
    return await Task.detached(priority: .userInitiated) { () -> UIImage? in
      switch kind {
      case .image:
        return UIImage(contentsOfFile: url.path)
      case .video:
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
          return nil
        }
        return UIImage(cgImage: cgImage)
      }
    }.value
  }
}
#endif
