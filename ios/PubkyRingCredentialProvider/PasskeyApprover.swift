import Foundation
import LocalAuthentication
import Security

/// Approves a validated request: the same work as performAuth in src/utils/pubky.ts, without
/// React Native. The pubky secret is read just in time and never leaves this function.
enum PasskeyApprover {
  enum Failure: LocalizedError {
    case secretUnavailable
    case deviceAuthFailed
    case authFailed(String)

    var errorDescription: String? {
      switch self {
      case .secretUnavailable: return "Pubky Ring could not read this pubky's key. Open Pubky Ring and try again."
      case .deviceAuthFailed: return "Device authentication was cancelled."
      case .authFailed(let message): return message
      }
    }
  }

  /// Returns whether the user was verified with device authentication (the UV flag).
  static func approve(
    url: String, identity: PasskeySnapshot.Identity, capabilities: String, requireDeviceAuth: Bool
  ) async throws -> Bool {
    var userVerified = false
    if requireDeviceAuth {
      let context = LAContext()
      do {
        userVerified = try await context.evaluatePolicy(
          .deviceOwnerAuthentication, localizedReason: "Authorise sign-in with \(identity.name)")
      } catch {
        throw Failure.deviceAuthFailed
      }
    }
    guard let secretKey = secretKey(for: identity) else { throw Failure.secretUnavailable }
    let result = await Task.detached(priority: .userInitiated) {
      authWithCapabilities(url: url, secretKey: secretKey, approvedCapabilities: capabilities)
    }.value
    if result.first?.lowercased() == "true" {
      throw Failure.authFailed(result.count > 1 ? result[1] : "Pubky Ring could not approve the sign-in.")
    }
    return userVerified
  }

  /// Ring stores `{secretKey, mnemonic}` JSON (older installs: the bare secret) under service = pubky.
  /// Adopted identities live in the shared group under "<sourceApp>:<pubky>" (SharedPubky.m).
  static func secretKey(for identity: PasskeySnapshot.Identity) -> String? {
    let raw: String?
    if let sourceApp = identity.sourceApp {
      raw = readKeychain(
        service: "pubky.shared.v1", account: "\(sourceApp):\(identity.pubky)",
        group: PasskeyShared.sharedKeychainGroup)
    } else {
      raw = readKeychain(service: identity.storeKey, account: nil, group: PasskeyShared.ringKeychainGroup)
    }
    guard let raw, !raw.isEmpty else { return nil }
    if let data = raw.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      return json["secretKey"] as? String
    }
    return raw
  }

  private static func readKeychain(service: String, account: String?, group: String) -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccessGroup as String: group,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}

/// Replay cache for envelope nonces, kept in the App Group until each envelope expires.
enum PasskeyNonceCache {
  static func has(_ nonce: Data) -> Bool {
    entries()[Base64Url.encode(nonce)] != nil
  }

  static func remember(_ nonce: Data, until exp: UInt32) {
    let now = UInt32(Date().timeIntervalSince1970)
    var all = entries().filter { $0.value + PasskeyPolicy.clockSkewSeconds >= now }
    all[Base64Url.encode(nonce)] = exp
    PasskeyShared.defaults?.set(all.mapValues { NSNumber(value: $0) }, forKey: PasskeyShared.seenNoncesKey)
  }

  private static func entries() -> [String: UInt32] {
    let raw = PasskeyShared.defaults?.dictionary(forKey: PasskeyShared.seenNoncesKey) ?? [:]
    return raw.compactMapValues { ($0 as? NSNumber)?.uint32Value }
  }
}
