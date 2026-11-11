import CryptoKit
import Foundation

/// iOS route for getting the envelope to Ring (PLAN.md section 4.5). The page encrypts E under a
/// key derived from its PRF input and posts it to the relay before calling navigator.credentials.get().
/// Twin of pubky-app src/libs/passkey/mailbox.ts and scripts/passkey/protocol-reference.js.
enum PasskeyMailbox {
  static let defaultRelay = "https://httprelay.pubky.app/inbox"
  static let keyInfo = "pubky-ring-webauthn-mailbox-v1/key"
  static let channelLabel = "pubky-ring-webauthn-mailbox-v1/channel"

  enum Failure: Error { case notFound, invalid }

  /// s = SHA-256("WebAuthn PRF" || 0x00 || r), as the WebAuthn client computes it.
  static func prfSalt(_ input: Data) -> Data {
    var data = Data("WebAuthn PRF".utf8)
    data.append(0)
    data.append(input)
    return Data(SHA256.hash(data: data))
  }

  static func key(salt: Data) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: salt), salt: Data(), info: Data(keyInfo.utf8), outputByteCount: 32)
  }

  static func channel(salt: Data) -> String {
    var data = Data(channelLabel.utf8)
    data.append(salt)
    return Base64Url.encode(Data(SHA256.hash(data: data)))
  }

  static func open(body: Data, salt: Data, rpId: String) throws -> Data {
    guard body.count > 12 + 16 else { throw Failure.invalid }
    let box = try AES.GCM.SealedBox(
      nonce: AES.GCM.Nonce(data: body.prefix(12)), ciphertext: body.dropFirst(12).dropLast(16),
      tag: body.suffix(16))
    return try AES.GCM.open(box, using: key(salt: salt), authenticating: Data(rpId.utf8))
  }

  /// `https://{rpId}/.well-known/pubky-auth.json` names the site's mailbox relay; otherwise Ring's default.
  static func relay(for rpId: String) async -> String {
    guard let url = URL(string: "https://\(rpId)/.well-known/pubky-auth.json") else { return defaultRelay }
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let relay = json["mailboxRelay"] as? String, relay.lowercased().hasPrefix("https://")
    else { return defaultRelay }
    return relay
  }

  /// Fetches and decrypts E. Whether iOS hands providers the hashed salt or the page's raw PRF input
  /// is unconfirmed, so both readings are tried.
  static func fetchEnvelope(prfInput: Data, rpId: String) async throws -> Data {
    let relay = await relay(for: rpId)
    let salts = [prfInput, prfSalt(prfInput)]
    return try await withThrowingTaskGroup(of: Data?.self) { group in
      for salt in salts {
        group.addTask { try? await fetch(relay: relay, salt: salt, rpId: rpId) }
      }
      for try await result in group {
        if let envelope = result {
          group.cancelAll()
          return envelope
        }
      }
      throw Failure.notFound
    }
  }

  private static func fetch(relay: String, salt: Data, rpId: String) async throws -> Data {
    guard let url = URL(string: "\(relay.hasSuffix("/") ? String(relay.dropLast()) : relay)/\(channel(salt: salt))")
    else { throw Failure.invalid }
    let (body, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.notFound }
    let envelope = try open(body: body, salt: salt, rpId: rpId)
    var delete = URLRequest(url: url, timeoutInterval: 5)
    delete.httpMethod = "DELETE"
    _ = try? await URLSession.shared.data(for: delete)
    return envelope
  }
}
