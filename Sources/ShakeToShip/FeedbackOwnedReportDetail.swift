import Foundation

struct FeedbackOwnedReportAttachment: Decodable, Sendable, Equatable {
  let file: String
  let kind: FeedbackMediaKind

  /// Segment 1 is recording.mov. The server admits 002 through 020 after it.
  static let maxRecordingSegments = 20
  static let maxAllowedFiles = maxRecordingSegments + FeedbackAttachmentBounds.maxItems * 2

  private enum CodingKeys: String, CodingKey { case file, kind }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let file = try values.decode(String.self, forKey: .file)
    let kind = try values.decode(FeedbackMediaKind.self, forKey: .kind)
    guard Self.valid(file: file, kind: kind) else {
      throw DecodingError.dataCorruptedError(
        forKey: .file, in: values, debugDescription: "Invalid report media file")
    }
    self.file = file
    self.kind = kind
  }

  static func valid(file: String, kind: FeedbackMediaKind) -> Bool {
    if file == FeedbackAttachmentNaming.recordingFile { return kind == .video }
    if kind == .video {
      for segment in 2...maxRecordingSegments {
        if file == String(format: "recording-%03d.mov", segment) { return true }
      }
    }
    for index in 0..<FeedbackAttachmentBounds.maxItems {
      if file == FeedbackAttachmentNaming.attachmentFile(index: index, kind: kind) {
        return true
      }
    }
    return false
  }
}

struct FeedbackOwnedReportDetail: Decodable, Sendable {
  let id: String
  let attachments: [FeedbackOwnedReportAttachment]

  private enum CodingKeys: String, CodingKey { case id, attachments }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let id = try values.decode(String.self, forKey: .id)
    let attachments = try values.decode([FeedbackOwnedReportAttachment].self, forKey: .attachments)
    guard Self.validID(id),
      attachments.count <= FeedbackOwnedReportAttachment.maxAllowedFiles,
      Set(attachments.map(\.file)).count == attachments.count
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .attachments, in: values, debugDescription: "Invalid report attachments")
    }
    self.id = id
    self.attachments = attachments
  }

  static func validID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 128
      && id.utf8.allSatisfy { byte in
        (65...90).contains(byte) || (97...122).contains(byte)
          || (48...57).contains(byte) || byte == 45 || byte == 95
      }
  }
}

#if canImport(UIKit)
import SwiftUI

struct FeedbackOwnedReportDetailView: View {
  @Bindable var model: FeedbackHubModel
  let report: FeedbackOwnedSession

  @Environment(\.shakeToShipTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  @State private var detail: FeedbackOwnedReportDetail?
  @State private var media: [FeedbackMediaItem] = []
  @State private var selected: FeedbackOwnedReportSelection?
  @State private var loading = false
  @State private var error: String?
  @State private var requestID = UUID()

  var body: some View {
    List {
      Section {
        LabeledContent("Created", value: report.createdAt.formatted(date: .abbreviated, time: .shortened))
          .feedbackPrimaryText()
      } header: {
        Text("Bug report").foregroundStyle(theme.secondaryText ?? .secondary)
      }.feedbackRow()

      Section {
        if loading { ProgressView("Loading attachments…").feedbackPrimaryText() }
        if let error {
          Text(error).foregroundStyle(theme.secondaryText ?? .secondary)
          Button("Try again") { Task { await load() } }
        }
        if let detail, detail.attachments.isEmpty {
          Text("This report has no attachments.")
            .foregroundStyle(theme.secondaryText ?? .secondary)
        }
        if !media.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 12) {
              ForEach(media) { item in
                Button { selected = FeedbackOwnedReportSelection(id: item.id) } label: {
                  FeedbackOwnedReportThumbnail(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.kind == .image ? "Open image attachment" : "Open video attachment")
              }
            }.padding(.vertical, 4)
          }.scrollIndicators(.hidden)
        }
      } header: {
        Text("Attachments").foregroundStyle(theme.secondaryText ?? .secondary)
      }.feedbackRow()
    }
    .feedbackListStyle()
    .navigationTitle("Report")
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .onChange(of: model.revision) { _, _ in
      requestID = UUID()
      media = []
      selected = nil
      dismiss()
    }
    .fullScreenCover(item: $selected) { selection in
      FeedbackAttachmentViewer(items: media, initialSelection: selection.id)
        .shakeToShipTheme(theme)
    }
  }

  private func load() async {
    guard model.active else { return }
    let expected = model.revision
    let currentRequest = UUID()
    requestID = currentRequest
    loading = true
    error = nil
    media = []
    defer { if requestID == currentRequest { loading = false } }
    await model.perform {
      do {
        let result = try await model.client.reportDetail(report.id)
        var loaded: [FeedbackMediaItem] = []
        var firstMediaError: Error?
        for attachment in result.attachments {
          do {
            let file = try await model.client.reportMedia(for: result, attachment: attachment)
            loaded.append(.picked(file, attachment.kind))
          } catch {
            if error as? FeedbackHubError == .identityChanged
              || error as? FeedbackHubError == .authentication
            { throw error }
            firstMediaError = firstMediaError ?? error
          }
        }
        guard model.active, expected == model.revision,
          requestID == currentRequest, !Task.isCancelled
        else { return }
        detail = result
        media = loaded
        self.error = firstMediaError?.localizedDescription
      } catch {
        if model.active, expected == model.revision, requestID == currentRequest {
          self.error = error.localizedDescription
        }
        throw error
      }
    }
  }
}

private struct FeedbackOwnedReportSelection: Identifiable {
  let id: URL
}

private struct FeedbackOwnedReportThumbnail: View {
  let item: FeedbackMediaItem
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      Color.black
      if let image {
        Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: item.kind == .video ? "film" : "photo")
          .foregroundStyle(.white)
      }
      if item.kind == .video {
        Image(systemName: "play.circle.fill")
          .font(.title).foregroundStyle(.white)
          .shadow(radius: 3)
      }
    }
    .frame(width: 112, height: 112)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .task(id: item.id) { image = await FeedbackMediaThumbnailLoader.load(item) }
  }
}
#endif
