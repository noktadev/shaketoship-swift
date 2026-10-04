import CryptoKit
import Foundation
import Security

/// Keychain identity and private disk data share a bundle/project/ingest namespace.
/// The upload credential hash prevents one project's data from reaching another project.
struct FeedbackHubStorage: Sendable {
  let scope: String
  let root: URL
  let readIdentity: @Sendable () throws -> Data?
  let writeIdentity: @Sendable (Data?) throws -> Void

  static func live(config: ShakeToShipConfig) -> Self {
    let context = [
      Bundle.main.bundleIdentifier ?? config.app, config.app,
      config.collectorURL.absoluteString, config.secret,
    ].joined(separator: "\u{0}")
    let scope = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("shaketoship-hub/" + scope, isDirectory: true)
    return Self(
      scope: scope, root: root,
      readIdentity: {
        var query = keychainQuery(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw FeedbackHubError.storage }
        return result as? Data
      },
      writeIdentity: { data in
        let query = keychainQuery(scope)
        guard let data else {
          let status = SecItemDelete(query as CFDictionary)
          guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FeedbackHubError.storage
          }
          return
        }
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
          var insert = query
          insert[kSecValueData as String] = data
          insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
          guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw FeedbackHubError.storage
          }
        } else if status != errSecSuccess {
          throw FeedbackHubError.storage
        }
      })
  }

  /// Clears this app's SDK identities before a recorder has mounted. No network is required.
  static func clearAllLocalIdentities() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "shaketoship.reporter.v3",
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw FeedbackHubError.storage
    }
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("shaketoship-hub", isDirectory: true)
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  }

  private static func keychainQuery(_ scope: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "shaketoship.reporter.v3",
      kSecAttrAccount as String: scope,
    ]
  }
  func write<T: Encodable>(_ value: T, file: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var directory = root
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    let url = root.appendingPathComponent(file)
    try JSONEncoder().encode(value).write(
      to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  func read<T: Decodable>(_ type: T.Type, file: String) throws -> T? {
    let url = root.appendingPathComponent(file)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
  func clearPrivateData() throws {
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  }
}

struct FeedbackCaptureBinding: Codable, Sendable, Equatable {
  let scope: String
  let generation: UUID
  let purpose: FeedbackCapturePurpose
  static let filename = ".reporter-binding.json"
  static func read(in directory: URL) throws -> Self? {
    let url = directory.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
}
struct FeedbackCapturePurpose: Codable, Sendable, Equatable {
  let kind: String
  let ideaId: String?
  static let report = Self(kind: "report", ideaId: nil)
  static func idea(_ id: String) -> Self { Self(kind: "idea", ideaId: id) }
}
struct FeedbackOwnedSession: Codable, Sendable, Identifiable, Equatable {
  let id: String  // Server session_record.id, never the external capture ID.
  let captureId: String
  let purpose: FeedbackCapturePurpose?
  let reporterId: String
  let generation: UUID
  let createdAt: Date
}
