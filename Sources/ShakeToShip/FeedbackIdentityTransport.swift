import Foundation

/// Cancellable transfer adapter for reporter-bound captures, including multipart control requests.
/// Legacy background transfers retain their existing behavior for hub-disabled hosts.
struct FeedbackIdentityTransport: FeedbackTransport {
  let client: FeedbackHubClient
  let binding: FeedbackCaptureBinding
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try await client.captureTransfer(request, file: nil, binding: binding)
  }
  func upload(_ request: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
    try await client.captureTransfer(request, file: file, binding: binding)
  }
}
