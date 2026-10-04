@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import ShakeToShip

@Suite(.serialized) struct FeedbackJamTests {
  @Test func trimFiltersAndRebasesEvents() {
    let range = FeedbackTrimRange(start: 2, end: 5)
    #expect(range.isValid(for: 10))
    #expect(!FeedbackTrimRange(start: .nan, end: 5).isValid(for: 10))
    #expect(!FeedbackTrimRange(start: 5, end: 2).isValid(for: 10))
    #expect(!FeedbackTrimRange(start: 2, end: 11).isValid(for: 10))
    #expect(range.events([.screen(t: 1, name: "Before"), .screen(t: 3, name: "Practice"),
      .tap(t: 4, tap: .init(x: 0.5, y: 0.4, element: "Unlock Pro")), .screen(t: 6, name: "After")]) == [
        .screen(t: 1, name: "Practice"), .tap(t: 2, tap: .init(x: 0.5, y: 0.4, element: "Unlock Pro"))])
  }

  @Test func devContextCountsTimelineAndCodableRoundTrip() throws {
    let events: [FeedbackEvent] = [.screen(t: 14, name: "Practice"),
      .tap(t: 23, tap: .init(x: 0, y: 0, element: "Unlock Pro"))]
    let counts = FeedbackDevContext.counts(events: events)
    #expect(counts.screens == 1 && counts.taps == 1)
    #expect(FeedbackDevContext.timeline(events: events) == ["0:00 Recording started", "0:14 Screen: Practice", "0:23 Tap: Unlock Pro"])
    let context = FeedbackDevContext(os: "iOS 26", device: "iPhone", appVersion: "1.2", build: "3",
      locale: "en_US", batteryPercent: nil, storageFreeBytes: nil, lowPower: true,
      screenWidth: 393, screenHeight: 852, screenCount: counts.screens, tapCount: counts.taps)
    #expect(try JSONDecoder().decode(FeedbackDevContext.self, from: JSONEncoder().encode(context)) == context)
    let session = FeedbackSession(session_id: "x", app: "test", build: "3", started_at: "now", events: events,
      dev_context: context, duration_seconds: 24)
    #expect(try JSONDecoder().decode(FeedbackSession.self, from: JSONEncoder().encode(session)) == session)
    let legacy = Data(#"{"session_id":"x","app":"a","build":"1","started_at":"now","events":[]}"#.utf8)
    #expect(try JSONDecoder().decode(FeedbackSession.self, from: legacy).dev_context == nil)
  }

  @Test @MainActor func ideasPresentationHonorsActivationAndOptions() async throws {
    let previous = ShakeToShip.model
    let present = ShakeToShip.present
    defer { ShakeToShip.model = previous; ShakeToShip.present = present }
    var routes: [Int] = []
    ShakeToShip.present = { routes.append($0) }
    ShakeToShip.model = nil
    ShakeToShip.presentIdeas()
    #expect(routes.isEmpty)
    let (client, root, _) = try FeedbackHubClientTests().fixture(transport: HubTestTransport())
    defer { try? FileManager.default.removeItem(at: root) }
    let config = await client.config
    let model = FeedbackHubModel(client: client, config: config)
    ShakeToShip.model = model
    ShakeToShip.presentIdeas()
    #expect(routes == [4])
    model.active = false
    ShakeToShip.presentIdeas()
    #expect(routes == [4])
    let disabled = ShakeToShipConfig(app: "test", collectorURL: URL(string: "https://fixture.invalid")!, secret: "test", hub: [.inbox])
    ShakeToShip.model = FeedbackHubModel(client: client, config: disabled)
    ShakeToShip.presentIdeas()
    #expect(routes == [4])
  }

  @Test func exportCannotRaceAnUploadLease() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let path = dir.standardizedFileURL.path
    #expect(await FeedbackUploadLeases.shared.acquire(path))
    await #expect(throws: FeedbackVideoRecoveryError.self) {
      try await FeedbackRecordingEdit.prepare(source: dir.appendingPathComponent("recording.mov"), in: dir,
        range: .init(start: 0, end: 1), context: nil, events: [])
    }
    await FeedbackUploadLeases.shared.release(path)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
  }

  @Test func exportedDurationIsDeclaredAndOnlyTrimmedMediaUploadsAcrossRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try await FeedbackVideoCompressionIntegrationTests().makeRecording(in: directory)
    try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("recording.mov"))
    try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("recording-002.mov"))
    let before = try Data(contentsOf: source)
    let canvas = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    canvas.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
    let annotation = try #require(canvas.makeImage())
    let edit = try await FeedbackRecordingEdit.prepare(source: source, in: directory,
      range: .init(start: 0.2, end: 0.7), context: nil,
      events: [.screen(t: 0.3, name: "Practice")], annotation: annotation)
    let exported = FeedbackRecordingEdit.file("recording.mov", in: directory)
    let duration = try await AVURLAsset(url: exported).load(.duration).seconds
    #expect(abs(duration - 0.5) < 0.05)
    #expect(edit.duration == duration)
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
    let frame = try await generator.image(at: .zero).image
    let pixels = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // Inspect a center pixel in the exported movie, not the preview or source image.
    pixels.draw(frame, in: CGRect(x: -31, y: -31, width: 64, height: 64))
    let rgba = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
    #expect(rgba[0] > 200 && rgba[1] < 60 && rgba[2] < 60)
    #expect(try Data(contentsOf: source) == before)
    #expect(try await AVURLAsset(url: exported).loadTracks(withMediaType: .audio).count == 1)
    let session = try JSONDecoder().decode(FeedbackSession.self, from: Data(contentsOf: FeedbackRecordingEdit.file("events.json", in: directory)))
    #expect(session.duration_seconds == duration)
    #expect(abs(session.events[0].t - 0.1) < 0.0001)
    let presign = Data(#"{"urls":{"events.json":"https://r2.example/events","recording.mov":"https://r2.example/video","complete.json":"https://r2.example/complete"}}"#.utf8)
    let transport = FakeTransport([.init(status: 200, data: presign), .init(status: 200, data: Data()),
      .init(status: 503, data: Data()), .init(status: 200, data: presign),
      .init(status: 200, data: Data()), .init(status: 200, data: Data())])
    let config = ShakeToShipConfig(app: "test", collectorURL: URL(string: "https://collector.example")!, secret: "test")
    let uploader = FeedbackUploader(config: config, transport: transport, fileManager: .default, outboxRoot: root)
    try Data().write(to: directory.appendingPathComponent(feedbackConfirmedMarker))
    try Data(#"{"version":1,"statusCode":403}"#.utf8).write(to: directory.appendingPathComponent(".upload-failure.json"))
    #expect(uploader.retainedRecordings().first?.originalFiles.map(\.lastPathComponent) == ["recording.mov", "recording-002.mov"])
    try FileManager.default.removeItem(at: directory.appendingPathComponent(".upload-failure.json"))
    #expect(await uploader.upload(sessionId: "capture") == .retryableFailure)
    #expect(await uploader.upload(sessionId: "capture") == .uploaded)
    for request in transport.requests where request.httpMethod == "POST" {
      let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
      #expect(body["capSeconds"] as? Double == duration)
      #expect(!(body["files"] as! [String]).contains("recording-002.mov"))
    }
    #expect(transport.uploads.filter { $0.file.lastPathComponent == "recording.mov" }.allSatisfy {
      $0.file.path.contains(".review-edits")
    })
  }
}
