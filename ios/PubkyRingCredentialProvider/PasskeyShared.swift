import CryptoKit
import Foundation

/// Compiled into both the app (PubkyPasskeyModule) and the credential provider extension.
enum PasskeyShared {
  static let snapshotFileName = "passkey_snapshot.json"
  static let registeredRpIdsKey = "passkey.registeredRpIds"
  static let seenNoncesKey = "passkey.seenNonces"

  /// App Group shared by the app and the extension, from `RING_APP_GROUP` in ios/Config/Signing.xcconfig.
  static var appGroup: String? {
    (Bundle.main.object(forInfoDictionaryKey: "PubkyAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Team prefix including the trailing dot, for example "ABCDE12345.".
  static var appIdentifierPrefix: String {
    Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? ""
  }

  /// Ring's own keychain items (react-native-keychain writes to the first entry of keychain-access-groups).
  static var ringKeychainGroup: String { "\(appIdentifierPrefix)app.pubkyring" }

  /// Cross-app group shared with Bitkit (see SharedPubky.m).
  static var sharedKeychainGroup: String { "\(appIdentifierPrefix)pubky.shared" }

  static var containerURL: URL? {
    appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
  }

  static var defaults: UserDefaults? { appGroup.flatMap { UserDefaults(suiteName: $0) } }

  /// SHA-256("pubky-ring-credential-v1" || 0 || rpId || 0 || pubky), first 16 bytes. Same as Android.
  static func credentialId(rpId: String, pubky: String) -> Data {
    var input = Data("pubky-ring-credential-v1".utf8)
    input.append(0)
    input.append(Data(rpId.utf8))
    input.append(0)
    input.append(Data(pubky.utf8))
    return Data(SHA256.hash(data: input).prefix(16))
  }

  static func shortPubky(_ pubky: String) -> String {
    pubky.count <= 12 ? pubky : "\(pubky.prefix(6))…\(pubky.suffix(6))"
  }

  /// rpIds the user registered Ring for with navigator.credentials.create(), per pubky.
  static func registeredRpIds() -> [String: [String]] {
    defaults?.dictionary(forKey: registeredRpIdsKey) as? [String: [String]] ?? [:]
  }

  static func addRegisteredRpId(_ rpId: String, pubky: String) {
    var all = registeredRpIds()
    var rpIds = Set(all[pubky] ?? [])
    rpIds.insert(rpId)
    all[pubky] = rpIds.sorted()
    defaults?.set(all, forKey: registeredRpIdsKey)
  }
}

/// Non-secret snapshot the app writes for the extension. Same shape as src/passkey/snapshot.ts.
struct PasskeySnapshot: Decodable {
  struct Identity: Decodable {
    let pubky: String
    let storeKey: String
    let name: String
    /// Ring's display name (getPubkyName); absent in snapshots from older app builds.
    let displayName: String?
    let sourceApp: String?
  }

  let version: Int
  let autoAuth: Bool
  let requireDeviceAuth: Bool
  let alwaysShowAuthDetails: Bool?
  let knownRpIds: [String]
  let identities: [Identity]

  static func load() -> PasskeySnapshot? {
    guard let url = PasskeyShared.containerURL?.appendingPathComponent(PasskeyShared.snapshotFileName),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? JSONDecoder().decode(PasskeySnapshot.self, from: data)
  }

  func identity(for pubky: String) -> Identity? {
    identities.first { $0.pubky == pubky }
  }
}
