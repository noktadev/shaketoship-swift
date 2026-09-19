import Foundation

/// Provider-independent HTTP transport. transferID identifies one immutable
/// object or multipart part, including its tenant and upload generation.
public protocol UploadTransport: Sendable {
  var supportsBackgroundUploads: Bool { get }
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
  func upload(_ request: URLRequest, fromFile file: URL, transferID: String) async throws -> (Data, HTTPURLResponse)
  /// Call only after the response has been saved in the caller's durable state.
  func acknowledge(transferID: String, file: URL) async
}

extension UploadTransport {
  public var supportsBackgroundUploads: Bool { false }
  public func acknowledge(transferID: String, file: URL) async {}
}

public enum UploadTransportError: Error, Sendable {
  case notHTTP
  case responseTooLarge
  case transferIdentityConflict
}
