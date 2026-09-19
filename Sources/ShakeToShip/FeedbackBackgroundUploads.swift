import AppUploads
import Foundation

/// Opt-in host lifecycle integration. Capture and confirmation stay in ShakeToShip;
/// AppUploads owns only file transfer and multipart protocol state.
@MainActor
public enum FeedbackBackgroundUploads {
  private static var session: BackgroundUploadSession?
  private static var configuration: ShakeToShipConfig?
  private static var root: URL?

  public static func configure(config: ShakeToShipConfig) {
    configuration = config
    guard session == nil else { return }
    let files = FileManager.default
    let documents = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
    root = documents.appendingPathComponent("feedback-outbox", isDirectory: true)
    let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    session = BackgroundUploadSession(
      identifier: (Bundle.main.bundleIdentifier ?? config.app) + ".feedback.uploads.v1",
      receiptDirectory: support.appendingPathComponent("feedback-transfer-receipts", isDirectory: true),
      onEventsDrained: { await resumeConfirmedUploads() })
    Task { await resumeConfirmedUploads() }
  }

  /// Forward UIApplicationDelegate's callback here after configure at launch.
  public static func handleEvents(
    forBackgroundURLSession identifier: String,
    completionHandler: @escaping @MainActor () -> Void
  ) -> Bool {
    session?.handleEvents(forBackgroundURLSession: identifier,
      completionHandler: completionHandler) ?? false
  }

  static var transport: any FeedbackTransport {
    if let session { return FeedbackBackgroundTransport(session: session) }
    return URLSessionTransport()
  }

  private static func resumeConfirmedUploads() async {
    guard let configuration, let root, let session else { return }
    await session.reconnect()
    let uploader = FeedbackUploader(config: configuration,
      transport: FeedbackBackgroundTransport(session: session),
      fileManager: .default, outboxRoot: root)
    _ = await uploader.retryOutbox()
  }
}

private struct FeedbackBackgroundTransport: FeedbackTransport {
  var supportsBackgroundUploads: Bool { true }
  let session: BackgroundUploadSession

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await session.perform(request)
  }

  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
    // Legacy whole-file PUT has no multipart checkpoint. Its signed destination
    // is part of the identity; refreshed URLs can safely repeat the same PUT.
    let id = "legacy:" + (request.url?.absoluteString ?? "") + ":" + file.path
    let result = try await session.upload(request, fromFile: file, transferID: id)
    if (200..<300).contains(result.1.statusCode) {
      await session.acknowledge(transferID: id, file: file)
    }
    return result
  }

  func upload(_ request: URLRequest, fromFile file: URL, transferID: String) async throws -> (Data, HTTPURLResponse) {
    try await session.upload(request, fromFile: file, transferID: transferID)
  }

  func acknowledge(transferID: String, file: URL) async {
    await session.acknowledge(transferID: transferID, file: file)
  }
}
