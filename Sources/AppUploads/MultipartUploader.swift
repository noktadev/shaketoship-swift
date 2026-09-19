import Foundation

public struct MultipartUploadCapabilities: Codable, Sendable {
  public let version: Int
  public let partSize: Int
  public let maximumBytes: Int?
  public init(version: Int, partSize: Int, maximumBytes: Int? = nil) {
    self.version = version; self.partSize = partSize; self.maximumBytes = maximumBytes
  }
  public var effectiveMaximumBytes: Int { min(maximumBytes ?? 5 * 1024 * 1024 * 1024, 5 * 1024 * 1024 * 1024) }
  public var isSupported: Bool { version == 1 && partSize == 10 * 1024 * 1024 && effectiveMaximumBytes > 0 }
}

/// Multipart state contains no original media and no short-lived signed URLs.
/// The resume token can renew the same upload through a fresh file presign.
struct MultipartUploadState: Codable, Sendable {
  struct Original: Codable, Equatable, Sendable {
    let size: Int
    let modifiedAt: Date
    let fingerprint: UploadFileFingerprint

    static func read(_ file: URL) throws -> Self {
      var fresh = file
      fresh.removeAllCachedResourceValues()
      let values = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
      guard values.isRegularFile == true, let size = values.fileSize,
            let modifiedAt = values.contentModificationDate else { throw MultipartUploadError.originalChanged }
      let fingerprint = try UploadFileFingerprint.read(file)
      fresh.removeAllCachedResourceValues()
      let after = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      guard fingerprint.bytes == size, after.fileSize == size, after.contentModificationDate == modifiedAt else {
        throw MultipartUploadError.originalChanged
      }
      return Self(size: size, modifiedAt: modifiedAt, fingerprint: fingerprint)
    }
  }

  struct Part: Codable, Sendable {
    let partNumber: Int
    let etag: String
    let receipt: String
  }

  let version: Int
  let original: Original
  let objectIdentity: String
  let contentType: String
  let generation: String
  var uploadID: String?
  var resumeToken: String?
  var parts: [Int: Part]
  var complete: Bool
}

public enum MultipartUploadError: Error {
  case http(Int)
  case invalidResponse
  case originalChanged
  case missingUpload
  case insufficientDiskSpace(requiredBytes: Int64)
  case sourceTooLarge(maximumBytes: Int)
}

public enum MultipartUploadScheduling: Sendable, Equatable {
  case bounded
  case backgroundQueued
}

public struct MultipartUploadProgress: Sendable, Equatable {
  public let completedBytes: Int
  public let totalBytes: Int
}

/// Worker/R2 multipart v1. The caller holds its upload lease and supplies a
/// fresh authenticated file URL on each attempt. The engine never deletes the
/// source. Bounded mode uploads two chunks at once. Background mode stages and
/// queues all missing chunks after a disk-space check; the transport limits
/// connections. Reads stay bounded to 10 MiB in either mode.
public struct MultipartUploader {
  private let transport: any UploadTransport
  private let fileManager: FileManager

  public init(transport: any UploadTransport, fileManager: FileManager = .default) {
    self.transport = transport
    self.fileManager = fileManager
  }

  private struct StartBody: Encodable {
    let size: Int
    let contentType: String
    let resumeToken: String?
  }
  private struct Start: Decodable {
    let uploadId: String
    let uploadToken: String
    let partSize: Int
    let status: String
  }
  private struct Status: Decodable { let status: String }
  private struct Complete: Encodable { let parts: [MultipartUploadState.Part] }

  public func upload(sourceURL file: URL, stateDirectory folder: URL, objectID: String, signedURL: URL,
                     capabilities capability: MultipartUploadCapabilities,
                     contentType: String = "application/octet-stream",
                     scheduling: MultipartUploadScheduling = .bounded,
                     onProgress: (@Sendable (MultipartUploadProgress) -> Void)? = nil) async throws {
    try Task.checkCancellation()
    guard capability.isSupported else { throw MultipartUploadError.invalidResponse }
    var freshSource = file
    freshSource.removeAllCachedResourceValues()
    if let size = try freshSource.resourceValues(forKeys: [.fileSizeKey]).fileSize,
       size > capability.effectiveMaximumBytes {
      throw MultipartUploadError.sourceTooLarge(maximumBytes: capability.effectiveMaximumBytes)
    }
    let original = try MultipartUploadState.Original.read(file)
    guard !objectID.isEmpty, objectID.utf8.count <= 2048 else { throw MultipartUploadError.invalidResponse }
    let objectIdentity = try Self.transferID(signedURL: signedURL, objectID: objectID, uploadID: "", partNumber: 0)
    guard capability.isSupported, original.size > 0, original.size <= 5 * 1024 * 1024 * 1024 else {
      throw MultipartUploadError.invalidResponse
    }
    let stateFile = folder.appendingPathComponent("state.json")
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    var state: MultipartUploadState
    if fileManager.fileExists(atPath: stateFile.path) {
      state = try JSONDecoder().decode(MultipartUploadState.self, from: Data(contentsOf: stateFile))
      guard state.version == 1, state.original == original, state.objectIdentity == objectIdentity, state.contentType == contentType else { throw MultipartUploadError.originalChanged }
    } else {
      state = MultipartUploadState(version: 1, original: original, objectIdentity: objectIdentity, contentType: contentType, generation: UUID().uuidString,
                                     parts: [:], complete: false)
      try save(state, to: stateFile)
    }


    var startRequest = URLRequest(url: try endpoint(signedURL, operation: "start"))
    startRequest.httpMethod = "POST"
    startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    startRequest.httpBody = try JSONEncoder().encode(StartBody(size: original.size,
      contentType: contentType,
      resumeToken: state.resumeToken))
    let start: Start = try await perform(startRequest)
    guard start.partSize == capability.partSize, !start.uploadId.isEmpty, !start.uploadToken.isEmpty,
          ["uploading", "complete"].contains(start.status),
          state.uploadID == nil || state.uploadID == start.uploadId else { throw MultipartUploadError.invalidResponse }
    state.uploadID = start.uploadId
    state.resumeToken = start.uploadToken
    try save(state, to: stateFile)

    do {
      let statusURL = try endpoint(signedURL, operation: "status", uploadID: start.uploadId, token: start.uploadToken)
      let status: Status = try await perform(URLRequest(url: statusURL))
      guard ["uploading", "complete"].contains(status.status) else { throw MultipartUploadError.invalidResponse }
      if status.status == "complete" {
        try assertOriginal(file, matches: original)
        state.complete = true
        try save(state, to: stateFile)
        onProgress?(MultipartUploadProgress(completedBytes: original.size, totalBytes: original.size))
        return
      }

      state.complete = false
      let count = (original.size + capability.partSize - 1) / capability.partSize
      guard state.parts.allSatisfy({ key, value in
        key == value.partNumber && key > 0 && key <= count && !value.etag.isEmpty && !value.receipt.isEmpty
      }) else { throw MultipartUploadError.invalidResponse }
      let missing = (1...count).filter { state.parts[$0] == nil }
      if scheduling == .backgroundQueued, !missing.isEmpty {
        let missingBytes = missing.reduce(Int64(0)) { total, part in
          total + Int64(min(capability.partSize, original.size - (part - 1) * capability.partSize))
        }
        let required = missingBytes * 2 + 32 * 1024 * 1024
        let attributes = try fileManager.attributesOfFileSystem(forPath: folder.path)
        guard let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value, available >= required else {
          throw MultipartUploadError.insufficientDiskSpace(requiredBytes: required)
        }
      }
      let chunks = folder.appendingPathComponent(state.generation, isDirectory: true)
      try fileManager.createDirectory(at: chunks, withIntermediateDirectories: true)
      for number in state.parts.keys {
        let chunk = chunks.appendingPathComponent("part-\(number)")
        if fileManager.fileExists(atPath: chunk.path) {
          let transferID = try Self.transferID(signedURL: signedURL, objectID: objectID, uploadID: start.uploadId, partNumber: number)
          await transport.acknowledge(transferID: transferID, file: chunk)
          try? fileManager.removeItem(at: chunk)
        }
      }
      let batchSize = scheduling == .backgroundQueued ? max(1, missing.count) : 2
      for offset in stride(from: 0, to: missing.count, by: batchSize) {
        try Task.checkCancellation()
        try assertOriginal(file, matches: original, verifyContents: false)
        var batch: [(Int, URL, URLRequest)] = []
        for number in missing[offset..<min(offset + batchSize, missing.count)] {
          try Task.checkCancellation()
          let chunk = chunks.appendingPathComponent("part-\(number)")
          let byteOffset = (number - 1) * capability.partSize
          let length = min(capability.partSize, original.size - byteOffset)
          try writeChunk(file, destination: chunk, offset: byteOffset, length: length)
          var request = URLRequest(url: try endpoint(signedURL, operation: "part", uploadID: start.uploadId,
                                                     token: start.uploadToken, partNumber: number))
          request.httpMethod = "PUT"
          request.setValue(String(length), forHTTPHeaderField: "Content-Length")
          request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
          batch.append((number, chunk, request))
        }
        let transport = self.transport
        try await withThrowingTaskGroup(of: (Int, Result<MultipartUploadState.Part, any Error>).self) { group in
          for (number, chunk, request) in batch {
            let transferID = try Self.transferID(signedURL: signedURL, objectID: objectID, uploadID: start.uploadId, partNumber: number)
            try Task.checkCancellation()
            group.addTask {
              do {
                try Task.checkCancellation()
                let (data, response) = try await transport.upload(request, fromFile: chunk, transferID: transferID)
                try Self.validateHTTP(data: data, response: response)
                let part = try JSONDecoder().decode(MultipartUploadState.Part.self, from: data)
                guard part.partNumber == number, !part.etag.isEmpty, !part.receipt.isEmpty else {
                  throw MultipartUploadError.invalidResponse
                }
                return (number, .success(part))
              } catch { return (number, .failure(error)) }
            }
          }
          var firstError: (any Error)?
          for try await (number, outcome) in group {
            switch outcome {
            case .success(let part):
              state.parts[part.partNumber] = part
              try save(state, to: stateFile)
              let chunk = chunks.appendingPathComponent("part-\(number)")
              let transferID = try Self.transferID(signedURL: signedURL, objectID: objectID, uploadID: start.uploadId, partNumber: number)
              await transport.acknowledge(transferID: transferID, file: chunk)
              try? fileManager.removeItem(at: chunk)
              let completedBytes = state.parts.keys.reduce(0) { total, part in
                total + min(capability.partSize, original.size - (part - 1) * capability.partSize)
              }
              onProgress?(MultipartUploadProgress(completedBytes: completedBytes, totalBytes: original.size))
            case .failure(let error): firstError = firstError ?? error
            }
          }
          if let firstError { throw firstError }
        }
      }
      try Task.checkCancellation()
      try assertOriginal(file, matches: original)
      var request = URLRequest(url: try endpoint(signedURL, operation: "complete", uploadID: start.uploadId, token: start.uploadToken))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(Complete(parts: state.parts.values.sorted { $0.partNumber < $1.partNumber }))
      let result: Status = try await perform(request)
      try assertOriginal(file, matches: original)
      guard result.status == "complete" else { throw MultipartUploadError.invalidResponse }
      state.complete = true
      try save(state, to: stateFile)
      onProgress?(MultipartUploadProgress(completedBytes: original.size, totalBytes: original.size))
    } catch MultipartUploadError.missingUpload {
      // Only a server-confirmed missing upload permits a new generation. Do
      // not retry within this attempt or confuse an expired URL with data loss.
      try save(MultipartUploadState(version: 1, original: original, objectIdentity: objectIdentity, contentType: contentType, generation: UUID().uuidString,
                                     parts: [:], complete: false), to: stateFile)
      throw MultipartUploadError.missingUpload
    }
  }

  /// The transfer identity contains the object location, never its credentials.
  static func transferID(signedURL: URL, objectID: String, uploadID: String, partNumber: Int) throws -> String {
    guard var object = URLComponents(url: signedURL, resolvingAgainstBaseURL: false) else {
      throw MultipartUploadError.invalidResponse
    }
    object.queryItems = (object.queryItems ?? []).filter {
      !["token", "multipart", "uploadId", "partNumber"].contains($0.name)
    }.sorted { $0.name < $1.name }
    object.fragment = nil
    guard let identity = object.string else { throw MultipartUploadError.invalidResponse }
    return "multipart-v1|\(identity)|\(objectID)|\(uploadID)|\(partNumber)"
  }

  private func perform<Value: Decodable>(_ request: URLRequest) async throws -> Value {
    let (data, response) = try await transport.perform(request)
    try Self.validateHTTP(data: data, response: response)
    return try JSONDecoder().decode(Value.self, from: data)
  }

  private static func validateHTTP(data: Data, response: HTTPURLResponse) throws {
    guard !(200..<300).contains(response.statusCode) else { return }
    struct Failure: Decodable { let code: String }
    if response.statusCode == 409,
       (try? JSONDecoder().decode(Failure.self, from: data).code) == "multipart_missing" {
      throw MultipartUploadError.missingUpload
    }
    throw MultipartUploadError.http(response.statusCode)
  }

  private func endpoint(_ signedURL: URL, operation: String, uploadID: String? = nil,
                        token: String? = nil, partNumber: Int? = nil) throws -> URL {
    guard var components = URLComponents(url: signedURL, resolvingAgainstBaseURL: false),
          components.scheme == "https", components.user == nil, components.password == nil else {
      throw MultipartUploadError.invalidResponse
    }
    var items = (components.queryItems ?? []).filter {
      !["multipart", "uploadId", "partNumber"].contains($0.name) && !(token != nil && $0.name == "token")
    }
    items.append(URLQueryItem(name: "multipart", value: operation))
    if let uploadID { items.append(URLQueryItem(name: "uploadId", value: uploadID)) }
    if let token { items.append(URLQueryItem(name: "token", value: token)) }
    if let partNumber { items.append(URLQueryItem(name: "partNumber", value: String(partNumber))) }
    components.queryItems = items
    guard let url = components.url else { throw MultipartUploadError.invalidResponse }
    return url
  }

  private func save(_ state: MultipartUploadState, to url: URL) throws {
    try JSONEncoder().encode(state).write(to: url, options: .atomic)
    #if os(iOS)
    try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    #endif
  }

  private func assertOriginal(_ file: URL, matches original: MultipartUploadState.Original, verifyContents: Bool = true) throws {
    if verifyContents {
      guard try MultipartUploadState.Original.read(file) == original else { throw MultipartUploadError.originalChanged }
    } else {
      var fresh = file
      fresh.removeAllCachedResourceValues()
      let values = try fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      guard values.fileSize == original.size, values.contentModificationDate == original.modifiedAt else {
        throw MultipartUploadError.originalChanged
      }
    }
  }

  private func writeChunk(_ file: URL, destination: URL, offset: Int, length: Int) throws {
    // Retain mtime and bytes so a restored background task can attach to the
    // same immutable chunk. The generation changes if the server upload resets.
    if fileManager.fileExists(atPath: destination.path) {
      let existing = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard existing.isRegularFile == true, existing.fileSize == length else { throw MultipartUploadError.originalChanged }
      return
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    guard let data = try handle.read(upToCount: length), data.count == length else { throw MultipartUploadError.originalChanged }
    try data.write(to: destination, options: .atomic)
    #if os(iOS)
    try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
    #endif
  }
}
