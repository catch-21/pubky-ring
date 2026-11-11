import CryptoKit
import Foundation
import Security

/// Per-(rpId, pubky) ES256 keys that sign WebAuthn assertions. They prove nothing about the pubky
/// (the grant on the relay does that), so they stay on this device: Secure Enclave where available,
/// a software key in the simulator.
enum CeremonyKeys {
  private static let service = "pubky-passkey-ceremony"

  enum Key {
    case enclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    var publicKey: P256.Signing.PublicKey {
      switch self {
      case .enclave(let key): return key.publicKey
      case .software(let key): return key.publicKey
      }
    }

    /// ECDSA-P256-SHA256, DER-encoded as WebAuthn requires.
    func sign(_ message: Data) throws -> Data {
      switch self {
      case .enclave(let key): return try key.signature(for: message).derRepresentation
      case .software(let key): return try key.signature(for: message).derRepresentation
      }
    }
  }

  static func loadOrCreate(credentialId: Data) throws -> Key {
    let account = Base64Url.encode(credentialId)
    if let stored = read(account: account) {
      if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) {
        return .enclave(key)
      }
      if let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) { return .software(key) }
    }
    let key: Key
    let representation: Data
    if SecureEnclave.isAvailable {
      let enclaveKey = try SecureEnclave.P256.Signing.PrivateKey()
      key = .enclave(enclaveKey)
      representation = enclaveKey.dataRepresentation
    } else {
      let softwareKey = P256.Signing.PrivateKey()
      key = .software(softwareKey)
      representation = softwareKey.rawRepresentation
    }
    try store(account: account, data: representation)
    return key
  }

  private static func query(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessGroup as String: PasskeyShared.ringKeychainGroup,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private static func read(account: String) -> Data? {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  private static func store(account: String, data: Data) throws {
    var item = query(account: account)
    SecItemDelete(item as CFDictionary)
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
  }
}
