import AppFeedbackCapture
import Foundation
import Testing

@testable import AppFeedback

/// State here crosses a real process boundary in production, so it crosses a
/// real notifyd round trip in the test too: every `isBroadcasting` assertion
/// below is driven by an actual Darwin notification post, not by poking a
/// subject. Removing the post would make every one of these tests fail.
@Suite struct FeedbackBroadcastManagerTests {
  // MARK: - Fixtures

  private func uniqueAppGroup() -> String {
    "group.test.\(UUID().uuidString).shaketoship"
  }

  private func makeTempRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("afb-bcast-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeUploader(root: URL, transport: FeedbackTransport = FakeTransport([]))
    -> FeedbackUploader
  {
    FeedbackUploader(
      config: FeedbackConfig(
        app: "dotself",
        collectorURL: URL(string: "https://collector.example.com")!,
        secret: "shh"),
      transport: transport,
      fileManager: .default,
      outboxRoot: root)
  }

  private func eventually(
    timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
  }

  // MARK: - State observation

  @Test func startsIdleUntilTheExtensionSaysOtherwise() throws {
    let root = try makeTempRoot()
    let group = uniqueAppGroup()
    let manager = FeedbackBroadcastManager(
      appGroupIdentifier: group,
      uploader: makeUploader(root: root),
      containerProvider: { BroadcastContainer(containerRoot: root) })

    #expect(manager.isBroadcasting == false)
  }

  @Test func isBroadcastingFollowsRealDarwinNotifications() async throws {
    let root = try makeTempRoot()
    let group = uniqueAppGroup()
    let manager = FeedbackBroadcastManager(
      appGroupIdentifier: group,
      uploader: makeUploader(root: root),
      containerProvider: { BroadcastContainer(containerRoot: root) })
    let signals = BroadcastSignals(appGroupIdentifier: group)

    DarwinSignals.post(signals.started)
    #expect(await eventually { manager.isBroadcasting })

    DarwinSignals.post(signals.stopped)
    #expect(await eventually { !manager.isBroadcasting })
  }

  @Test func thePublisherEmitsEveryTransitionForAUIToBindTo() async throws {
    let root = try makeTempRoot()
    let group = uniqueAppGroup()
    let manager = FeedbackBroadcastManager(
      appGroupIdentifier: group,
      uploader: makeUploader(root: root),
      containerProvider: { BroadcastContainer(containerRoot: root) })
    let seen = StateLog()
    let cancellable = manager.isBroadcastingPublisher.sink { seen.append($0) }
    defer { cancellable.cancel() }
    let signals = BroadcastSignals(appGroupIdentifier: group)

    DarwinSignals.post(signals.started)
    #expect(await eventually { seen.values.contains(true) })
    DarwinSignals.post(signals.stopped)
    #expect(await eventually { seen.values.suffix(1) == [false] })

    // Current-value semantics: a late subscriber still learns the state.
    #expect(seen.values.first == false)
  }

  @Test func anotherAppsBroadcastDoesNotFlipOurState() async throws {
    let root = try makeTempRoot()
    let manager = FeedbackBroadcastManager(
      appGroupIdentifier: uniqueAppGroup(),
      uploader: makeUploader(root: root),
      containerProvider: { BroadcastContainer(containerRoot: root) })
    let stranger = BroadcastSignals(appGroupIdentifier: uniqueAppGroup())

    DarwinSignals.post(stranger.started)
    // Give a delivery that must never arrive time to arrive anyway.
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(manager.isBroadcasting == false)
  }

  // MARK: - Stop

  @Test func requestStopPostsTheSignalTheExtensionIsListeningFor() async throws {
    let root = try makeTempRoot()
    let group = uniqueAppGroup()
    let manager = FeedbackBroadcastManager(
      appGroupIdentifier: group,
      uploader: makeUploader(root: root),
      containerProvider: { BroadcastContainer(containerRoot: root) })
    // Stands in for the extension process: a real observer on the real name.
    let heard = StateLog()
    let observation = try #require(
      DarwinSignals.observe(BroadcastSignals(appGroupIdentifier: group).requestStop) {
        heard.append(true)
      })
    defer { observation.cancel() }

    manager.requestStop()

    #expect(await eventually { heard.values.isEmpty == false })
  }

  // MARK: - Activation

  @Test @MainActor func activationReportsUnavailableWhenThereIsNoPickerOnThisPlatform() throws {
    let root = try makeTempRoot()
    let manager = FeedbackBroadcastManager(
      appGroupIdentifier: uniqueAppGroup(),
      uploader: makeUploader(root: root),
      containerProvider: { BroadcastContainer(containerRoot: root) },
      pickerProvider: { nil })

    #expect(manager.requestActivation() == .unavailable)
  }

  @Test @MainActor func activationDrivesThePickerWithTheDiscoveredExtensionId() throws {
    final class FakePicker: BroadcastPicker {
      var respondsToButtonPressed = true
      private(set) var configuredExtension: String??
      private(set) var pressed = false
      func configure(preferredExtension: String?, showsMicrophoneButton: Bool) {
        configuredExtension = preferredExtension
      }
      func pressButton() { pressed = true }
      func presentRawPicker() -> Bool { true }
    }
    let root = try makeTempRoot()
    let picker = FakePicker()
    let manager = FeedbackBroadcastManager(
      appGroupIdentifier: uniqueAppGroup(),
      uploader: makeUploader(root: root),
      preferredExtension: "com.example.app.broadcast",
      containerProvider: { BroadcastContainer(containerRoot: root) },
      pickerProvider: { picker })

    #expect(manager.requestActivation() == .pressedProgrammatically)
    #expect(picker.configuredExtension == "com.example.app.broadcast")
    #expect(picker.pressed)
  }

  // MARK: - Unreachable App Group

  @Test func harvestFailsLoudlyWhenTheAppGroupIsNotProvisioned() async throws {
    let root = try makeTempRoot()
    let group = uniqueAppGroup()
    // `group.<bundle>.shaketoship` is provisioned nowhere yet (#839), so this
    // is today's real behaviour, not a hypothetical.
    let manager = FeedbackBroadcastManager(
      appGroupIdentifier: group,
      uploader: makeUploader(root: root),
      containerProvider: { nil })

    await #expect(throws: FeedbackBroadcastError.appGroupUnavailable(identifier: group)) {
      try await manager.harvest()
    }
  }

  @Test func theAppGroupErrorNamesTheGroupItCouldNotReach() {
    let error = FeedbackBroadcastError.appGroupUnavailable(
      identifier: "group.com.example.app.shaketoship")

    // A diagnostic that does not name the missing group sends the reader
    // hunting; an empty session list would not even do that much.
    #expect(error.description.contains("group.com.example.app.shaketoship"))
    #expect(error.description.lowercased().contains("app group"))
  }
}

/// Thread-safe append-only log - notification handlers run off the test's queue.
final class StateLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Bool] = []

  func append(_ value: Bool) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
