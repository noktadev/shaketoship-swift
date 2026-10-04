import Foundation
import Testing

@testable import ShakeToShip

@Suite struct FeedbackOwnedReportTests {
  private let reportID = "report-1"

  private func ownedClient() async throws -> (
    FeedbackHubClient, HubTestTransport, FeedbackHubStorage, URL
  ) {
    let transport = HubTestTransport()
    let (client, root, storage) = try FeedbackHubClientTests().fixture(
      transport: transport, hub: [.inbox])
    await client.setActive(true)
    await transport.prepare([(201, hubIdentityJSON())])
    let reporter = try await client.identity()
    let binding = FeedbackCaptureBinding(
      scope: storage.scope, generation: await client.generation, purpose: .report)
    try await client.saveSessionRecord(
      reportID, captureId: "capture-1", binding: binding, reporter: reporter)
    return (client, transport, storage, root)
  }

  @Test func detailAcceptsOnlyKnownMediaNamesAndMatchingKinds() throws {
    let valid = #"{"id":"report-1","attachments":[{"file":"recording.mov","kind":"video"},{"file":"attachment-0.jpg","kind":"image"},{"file":"attachment-1.mov","kind":"video"}]}"#
    let detail = try JSONDecoder().decode(FeedbackOwnedReportDetail.self, from: Data(valid.utf8))
    #expect(detail.attachments.count == 3)
    for file in ["../recording.mov", "attachment-3.jpg", "note.txt", "attachment-0.mov/other"] {
      let invalid = "{\"id\":\"report-1\",\"attachments\":[{\"file\":\"\(file)\",\"kind\":\"image\"}]}"
      #expect(throws: Error.self) {
        _ = try JSONDecoder().decode(FeedbackOwnedReportDetail.self, from: Data(invalid.utf8))
      }
    }
    let wrongKind = #"{"id":"report-1","attachments":[{"file":"recording.mov","kind":"image"}]}"#
    #expect(throws: Error.self) {
      _ = try JSONDecoder().decode(FeedbackOwnedReportDetail.self, from: Data(wrongKind.utf8))
    }
    let duplicate = #"{"id":"report-1","attachments":[{"file":"attachment-0.jpg","kind":"image"},{"file":"attachment-0.jpg","kind":"image"}]}"#
    #expect(throws: Error.self) {
      _ = try JSONDecoder().decode(FeedbackOwnedReportDetail.self, from: Data(duplicate.utf8))
    }
  }

  @Test func detailAcceptsTheFullSegmentAndAttachmentAllowlist() throws {
    let recordings = ["recording.mov"]
      + (2...20).map { String(format: "recording-%03d.mov", $0) }
    let descriptors = recordings.map { "{\"file\":\"\($0)\",\"kind\":\"video\"}" }
      + (0..<FeedbackAttachmentBounds.maxItems).flatMap { index in
        ["jpg", "mov"].map { ext in
          let kind = ext == "jpg" ? "image" : "video"
          return "{\"file\":\"attachment-\(index).\(ext)\",\"kind\":\"\(kind)\"}"
        }
      }
    let payload = "{\"id\":\"report-1\",\"attachments\":[\(descriptors.joined(separator: ","))]}"
    let detail = try JSONDecoder().decode(FeedbackOwnedReportDetail.self, from: Data(payload.utf8))
    #expect(detail.attachments.count == 26)
    #expect(detail.attachments.last?.file == "attachment-2.mov")
    for file in ["recording-001.mov", "recording-021.mov", "recording-2.mov", "recording-020.jpg"] {
      let invalid = "{\"id\":\"report-1\",\"attachments\":[{\"file\":\"\(file)\",\"kind\":\"video\"}]}"
      #expect(throws: Error.self) {
        _ = try JSONDecoder().decode(FeedbackOwnedReportDetail.self, from: Data(invalid.utf8))
      }
    }
    let overflow = "{\"id\":\"report-1\",\"attachments\":[\(descriptors.joined(separator: ",")),\(descriptors[0])]}"
    #expect(throws: Error.self) {
      _ = try JSONDecoder().decode(FeedbackOwnedReportDetail.self, from: Data(overflow.utf8))
    }
  }

  @Test func segmentMediaDownloadsThroughAuthenticatedReportRoute() async throws {
    let (client, transport, _, root) = try await ownedClient()
    defer { try? FileManager.default.removeItem(at: root) }
    let response = #"{"id":"report-1","attachments":[{"file":"recording-002.mov","kind":"video"},{"file":"recording-020.mov","kind":"video"}]}"#
    await transport.prepare([(200, response), (200, "segment-two"), (200, "segment-twenty")])
    let detail = try await client.reportDetail(reportID)
    let first = try await client.reportMedia(for: detail, attachment: detail.attachments[0])
    let last = try await client.reportMedia(for: detail, attachment: detail.attachments[1])
    #expect(first.lastPathComponent == "recording-002.mov")
    #expect(last.lastPathComponent == "recording-020.mov")
    #expect(try String(contentsOf: first, encoding: .utf8) == "segment-two")
    #expect(try String(contentsOf: last, encoding: .utf8) == "segment-twenty")
    let requests = await transport.requests.suffix(2)
    #expect(requests.map { $0.url?.path } == [
      "/v2/reports/report-1/media/recording-002.mov",
      "/v2/reports/report-1/media/recording-020.mov",
    ])
    #expect(requests.allSatisfy {
      $0.value(forHTTPHeaderField: "x-feedback-secret") == "project-secret"
        && $0.value(forHTTPHeaderField: "x-reporter-token") != nil
        && $0.url?.query?.contains("app=com.example.test") == true
    })
    #expect(!last.absoluteString.contains("rt1."))
  }

  @Test func authenticatedMediaUsesLocalCacheAndResetDeletesIt() async throws {
    let (client, transport, _, root) = try await ownedClient()
    defer { try? FileManager.default.removeItem(at: root) }
    let response = #"{"id":"report-1","attachments":[{"file":"attachment-0.jpg","kind":"image"}]}"#
    await transport.prepare([(200, response), (200, "image-bytes")])
    let detail = try await client.reportDetail(reportID)
    let attachment = try #require(detail.attachments.first)
    let file = try await client.reportMedia(for: detail, attachment: attachment)
    #expect(file.isFileURL)
    #expect(try String(contentsOf: file, encoding: .utf8) == "image-bytes")
    let requestCount = await transport.requests.count
    #expect(try await client.reportMedia(for: detail, attachment: attachment) == file)
    #expect(await transport.requests.count == requestCount)
    let requests = await transport.requests
    let detailRequest = requests[requests.count - 2]
    let mediaRequest = requests[requests.count - 1]
    #expect(detailRequest.url?.path == "/v2/reports/report-1")
    #expect(mediaRequest.url?.path == "/v2/reports/report-1/media/attachment-0.jpg")
    #expect(mediaRequest.url?.query?.contains("app=com.example.test") == true)
    #expect(mediaRequest.value(forHTTPHeaderField: "x-feedback-secret") == "project-secret")
    #expect(mediaRequest.value(forHTTPHeaderField: "x-reporter-token") != nil)
    #expect(!file.absoluteString.contains("rt1."))
    try await client.reset()
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func otherReportIDsCannotReachTheNetwork() async throws {
    let (client, transport, _, root) = try await ownedClient()
    defer { try? FileManager.default.removeItem(at: root) }
    let count = await transport.requests.count
    await #expect(throws: FeedbackHubError.self) {
      _ = try await client.reportDetail("another-report")
    }
    await #expect(throws: FeedbackHubError.self) {
      _ = try await client.reportDetail("../report-1")
    }
    #expect(await transport.requests.count == count)
  }

  @Test func resetDuringMediaRequestCannotWriteOldReporterBytes() async throws {
    let (client, transport, _, root) = try await ownedClient()
    defer { try? FileManager.default.removeItem(at: root) }
    let response = #"{"id":"report-1","attachments":[{"file":"attachment-0.jpg","kind":"image"}]}"#
    await transport.prepare([(200, response)])
    let detail = try await client.reportDetail(reportID)
    let attachment = try #require(detail.attachments.first)
    let before = await transport.requests.count
    await transport.prepare([(200, "old-reporter-bytes")], suspend: true)
    let download = Task { try await client.reportMedia(for: detail, attachment: attachment) }
    for _ in 0..<1_000 {
      if await transport.requests.count > before { break }
      await Task.yield()
    }
    #expect(await transport.requests.count == before + 1)
    try await client.reset()
    await transport.resume()
    await #expect(throws: FeedbackHubError.self) { _ = try await download.value }
    let oldFile = root.appendingPathComponent("report-media/report-1/attachment-0.jpg")
    #expect(!FileManager.default.fileExists(atPath: oldFile.path))
  }
}
