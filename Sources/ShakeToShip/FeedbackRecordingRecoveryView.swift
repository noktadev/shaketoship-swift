import Foundation

/// Export owns independent copies, so successful background uploads cannot
/// remove files while another app or the Files sheet still reads them.
struct FeedbackRecordingExportCopy: Sendable {
  let directory: URL
  let files: [URL]

  static func prepare(_ recording: FeedbackRetainedRecording) async throws -> Self {
    guard let first = recording.originalFiles.first else { throw CocoaError(.fileNoSuchFile) }
    let sourceDirectory = first.deletingLastPathComponent().standardizedFileURL
    guard recording.originalFiles.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == sourceDirectory }) else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    let path = sourceDirectory.path
    guard await FeedbackUploadLeases.shared.acquire(path) else { throw CocoaError(.fileLocking) }
    do {
      let result = try await Task.detached(priority: .utility) {
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("feedback-export-" + UUID().uuidString, isDirectory: true)
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          var files: [URL] = []
          for source in recording.originalFiles {
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            files.append(destination)
          }
          return Self(directory: directory, files: files)
        } catch {
          try? FileManager.default.removeItem(at: directory)
          throw error
        }
      }.value
      await FeedbackUploadLeases.shared.release(path)
      return result
    } catch {
      await FeedbackUploadLeases.shared.release(path)
      throw error
    }
  }

  func removeCopies() { try? FileManager.default.removeItem(at: directory) }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

@MainActor
struct FeedbackRecordingRecoveryView: View {
  let recording: FeedbackRetainedRecording
  let onRetry: @MainActor () async -> FeedbackUploadResult
  let onClose: () -> Void
  @State private var retrying = false
  @State private var sharing = false
  @State private var preparingExport = false
  @State private var exportCopy: FeedbackRecordingExportCopy?
  @State private var message: String?

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Your recording is saved on this device.")
            .font(.headline)
          Text("The upload did not finish. Try a smaller upload, or export the original recording to Files or another app.")
          Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
            .foregroundStyle(.secondary)
          if let message { Text(message).accessibilityIdentifier("feedback-recovery-status") }
        }
        Section {
          Button {
            retrying = true
            Task {
              let result = await onRetry()
              retrying = false
              if result == .uploaded { onClose() }
              else {
                message = "The upload still could not finish. Your original recording is available to export."
              }
            }
          } label: {
            if retrying { ProgressView("Preparing upload…") }
            else { Label("Try smaller upload", systemImage: "arrow.clockwise") }
          }
          .disabled(retrying || preparingExport)
          Button {
            preparingExport = true
            Task {
              do {
                exportCopy = try await FeedbackRecordingExportCopy.prepare(recording)
                sharing = true
              } catch {
                message = "Could not prepare the export. Your saved recording stays on this device. Please try again."
              }
              preparingExport = false
            }
          } label: {
            Label(preparingExport ? "Preparing export…" : "Export original recording", systemImage: "square.and.arrow.up")
          }
          // Upload success removes the completed outbox directory. Do not race
          // an export against that cleanup; sharing itself never removes files.
          .disabled(retrying || preparingExport || recording.originalFiles.isEmpty)
          .accessibilityIdentifier("feedback-export-recording")
        }
        Section {
          Text("Export does not remove the saved recording from this device.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Keep your recording")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Later", action: onClose).disabled(retrying || preparingExport) } }
      .sheet(isPresented: $sharing, onDismiss: {
        exportCopy?.removeCopies()
        exportCopy = nil
      }) {
        if let exportCopy { FeedbackRecordingExport(files: exportCopy.files) }
      }
    }
    .interactiveDismissDisabled(retrying || preparingExport)
  }
}

@MainActor
struct FeedbackRecordingExport: UIViewControllerRepresentable {
  let files: [URL]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: files, applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
