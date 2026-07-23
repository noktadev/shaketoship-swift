import Foundation
import Testing

@testable import AppFeedbackCapture

@Suite struct BroadcastManifestTests {
  private func tempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("manifest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func roundTripsThroughDiskInEveryState() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // All four states must survive a real write/read cycle: the extension
    // writes them from a different process than the one that reads them.
    for state in BroadcastManifest.State.allCases {
      let manifest = BroadcastManifest(
        sessionId: "session-\(state.rawValue)",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        appBundleId: "com.example.host",
        sdkVersion: "1.2.3",
        hasNarration: true,
        hasAppAudio: false,
        capSeconds: 300,
        state: state,
        durationSeconds: 12.5,
        byteCount: 4_096)

      let url = dir.appendingPathComponent("\(state.rawValue).json")
      try BroadcastManifest.encoder.encode(manifest).write(to: url, options: .atomic)
      let decoded = try BroadcastManifest.decoder.decode(
        BroadcastManifest.self, from: Data(contentsOf: url))

      #expect(decoded == manifest)
      #expect(decoded.state == state)
    }
    #expect(BroadcastManifest.State.allCases.count == 4)
  }

  @Test func stateIsPersistedAsAStableString() throws {
    let manifest = BroadcastManifest(
      sessionId: "s1",
      startedAt: Date(timeIntervalSince1970: 0),
      appBundleId: "com.example.host",
      sdkVersion: "1.0.0",
      hasNarration: false,
      hasAppAudio: true,
      capSeconds: 60,
      state: .aborted)

    let json = try #require(
      String(data: try BroadcastManifest.encoder.encode(manifest), encoding: .utf8))

    // Raw strings, not ordinals: an enum reorder must never silently
    // reinterpret manifests already on disk from an older SDK build.
    #expect(json.contains("\"state\":\"aborted\""))
    #expect(manifest.durationSeconds == nil)
    #expect(manifest.byteCount == nil)
  }
}
