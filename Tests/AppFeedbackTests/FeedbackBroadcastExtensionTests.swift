import Foundation
import Testing

@testable import AppFeedback

/// Runs against a real `PlugIns` directory on disk holding real `Info.plist`
/// files - the same shape `Bundle.main.builtInPlugInsURL` points at inside a
/// shipped `.app`. Nothing is stubbed: the discovery reads the plists it will
/// read on device.
@Suite struct FeedbackBroadcastExtensionTests {
  private func makePlugIns(
    _ appexes: [(name: String, bundleId: String, pointIdentifier: String?)]
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-plugins-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for appex in appexes {
      let dir = root.appendingPathComponent("\(appex.name).appex", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var info: [String: Any] = ["CFBundleIdentifier": appex.bundleId]
      if let point = appex.pointIdentifier {
        info["NSExtension"] = ["NSExtensionPointIdentifier": point]
      }
      let data = try PropertyListSerialization.data(
        fromPropertyList: info, format: .xml, options: 0)
      try data.write(to: dir.appendingPathComponent("Info.plist"))
    }
    return root
  }

  @Test func picksTheUploadExtensionAndIgnoresItsSetupUISibling() throws {
    // A ReplayKit extension ships as a PAIR. `preferredExtension` must be the
    // upload one; pointing it at the setup-UI appex silently never records.
    let plugIns = try makePlugIns([
      ("SetupUI", "com.example.app.broadcastsetupui", "com.apple.broadcast-services-setupui"),
      ("Broadcast", "com.example.app.broadcast", "com.apple.broadcast-services-upload"),
      ("Widget", "com.example.app.widget", "com.apple.widgetkit-extension"),
    ])

    #expect(
      FeedbackBroadcastExtension.discover(inPlugInsAt: plugIns) == "com.example.app.broadcast")
  }

  @Test func returnsNilWhenNoBroadcastUploadExtensionIsInstalled() throws {
    let plugIns = try makePlugIns([
      ("Widget", "com.example.app.widget", "com.apple.widgetkit-extension"),
      ("Legacy", "com.example.app.legacy", nil),
    ])

    #expect(FeedbackBroadcastExtension.discover(inPlugInsAt: plugIns) == nil)
  }

  @Test func returnsNilWhenThereIsNoPlugInsDirectoryAtAll() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-absent-\(UUID().uuidString)", isDirectory: true)

    #expect(FeedbackBroadcastExtension.discover(inPlugInsAt: missing) == nil)
    #expect(FeedbackBroadcastExtension.discover(inPlugInsAt: nil) == nil)
  }

  @Test func picksDeterministicallyWhenAHostSomehowShipsTwoUploadExtensions() throws {
    let plugIns = try makePlugIns([
      ("Second", "com.example.app.zbroadcast", "com.apple.broadcast-services-upload"),
      ("First", "com.example.app.abroadcast", "com.apple.broadcast-services-upload"),
    ])

    // Directory enumeration order is not guaranteed; the answer must be.
    #expect(
      FeedbackBroadcastExtension.discover(inPlugInsAt: plugIns) == "com.example.app.abroadcast")
  }
}
