import CryptoKit
import Foundation

/// The few WebAuthn structures a passkey provider builds itself (PLAN.md section 5.3).
enum WebAuthnEncoding {
  private static let flagUserPresent: UInt8 = 0x01
  private static let flagUserVerified: UInt8 = 0x04
  /// iOS rejects every other combination of these two bits with
  /// "AuthData is missing a required flag", then Safari reports a cancellation.
  private static let flagBackupEligible: UInt8 = 0x08
  private static let flagBackupState: UInt8 = 0x10
  private static let flagAttestedData: UInt8 = 0x40

  /// rpIdHash | flags | signCount. signCount stays 0: ceremony keys never leave the device.
  static func authenticatorData(rpId: String, userVerified: Bool, attestedCredentialData: Data? = nil) -> Data {
    var data = Data(SHA256.hash(data: Data(rpId.utf8)))
    var flags = flagUserPresent | flagBackupEligible | flagBackupState
    if userVerified { flags |= flagUserVerified }
    if attestedCredentialData != nil { flags |= flagAttestedData }
    data.append(flags)
    data.append(contentsOf: [0, 0, 0, 0])
    if let attestedCredentialData { data.append(attestedCredentialData) }
    return data
  }

  /// AAGUID (zero) | credentialIdLength u16 | credentialId | COSE_Key (ES256).
  static func attestedCredentialData(credentialId: Data, publicKey: P256.Signing.PublicKey) -> Data {
    var data = Data(count: 16)
    data.append(UInt8(credentialId.count >> 8))
    data.append(UInt8(credentialId.count & 0xff))
    data.append(credentialId)
    data.append(coseKey(publicKey))
    return data
  }

  static func coseKey(_ publicKey: P256.Signing.PublicKey) -> Data {
    let point = publicKey.x963Representation
    var cbor = CBOR()
    cbor.map(count: 5)
    cbor.int(1); cbor.int(2)  // kty: EC2
    cbor.int(3); cbor.int(-7)  // alg: ES256
    cbor.int(-1); cbor.int(1)  // crv: P-256
    cbor.int(-2); cbor.bytes(point.subdata(in: 1..<33))
    cbor.int(-3); cbor.bytes(point.subdata(in: 33..<65))
    return cbor.data
  }

  /// {"fmt": "none", "attStmt": {}, "authData": authData}
  static func noneAttestationObject(authData: Data) -> Data {
    var cbor = CBOR()
    cbor.map(count: 3)
    cbor.text("fmt"); cbor.text("none")
    cbor.text("attStmt"); cbor.map(count: 0)
    cbor.text("authData"); cbor.bytes(authData)
    return cbor.data
  }
}

/// Minimal canonical CBOR writer: just the major types the structures above use.
struct CBOR {
  private(set) var data = Data()

  private mutating func head(_ major: UInt8, _ value: UInt64) {
    let type = major << 5
    switch value {
    case 0..<24: data.append(type | UInt8(value))
    case 24..<0x100: data.append(contentsOf: [type | 24, UInt8(value)])
    case 0x100..<0x10000: data.append(contentsOf: [type | 25, UInt8(value >> 8), UInt8(value & 0xff)])
    default:
      data.append(type | 26)
      data.append(contentsOf: (0..<4).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xff) })
    }
  }

  mutating func int(_ value: Int) {
    if value >= 0 { head(0, UInt64(value)) } else { head(1, UInt64(-1 - value)) }
  }

  mutating func bytes(_ value: Data) {
    head(2, UInt64(value.count))
    data.append(value)
  }

  mutating func text(_ value: String) {
    let utf8 = Data(value.utf8)
    head(3, UInt64(utf8.count))
    data.append(utf8)
  }

  mutating func map(count: Int) { head(5, UInt64(count)) }
}
