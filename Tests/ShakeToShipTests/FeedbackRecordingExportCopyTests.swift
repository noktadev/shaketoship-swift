import Foundation
import XCTest
@testable import ShakeToShip

final class FeedbackRecordingExportCopyTests: XCTestCase {
  func test_exportSurvivesOriginalUploadCleanupAndOnlyDeletesItsOwnCopies() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("recording.mov")
    let contents = Data("complete original recording".utf8)
    try contents.write(to: original)
    let recording = FeedbackRetainedRecording(sessionId: "session", originalFiles: [original], createdAt: Date())
    let first = try await FeedbackRecordingExportCopy.prepare(recording)
    first.removeCopies()
    XCTAssertEqual(try Data(contentsOf: original), contents)
    let second = try await FeedbackRecordingExportCopy.prepare(recording)
    defer { second.removeCopies() }
    try FileManager.default.removeItem(at: original)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(second.files.first)), contents)
  }

  func test_exportCannotRaceAnActiveUpload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let path = directory.standardizedFileURL.path
    let acquired = await FeedbackUploadLeases.shared.acquire(path)
    XCTAssertTrue(acquired)
    let recording = FeedbackRetainedRecording(sessionId: "session",
      originalFiles: [directory.appendingPathComponent("recording.mov")], createdAt: Date())
    do {
      let copies = try await FeedbackRecordingExportCopy.prepare(recording)
      copies.removeCopies()
      XCTFail("Export must wait until the upload releases its original files")
    } catch {
      XCTAssertEqual((error as NSError).code, CocoaError.fileLocking.rawValue)
    }
    await FeedbackUploadLeases.shared.release(path)
  }
}
