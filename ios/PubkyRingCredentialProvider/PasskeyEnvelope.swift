import Foundation

/// Pubky WebAuthn envelope ("E"). Twin of src/passkey/envelope.ts; layout, big-endian:
/// magic "PKYWA1" (6) | version u8 | flags u8 | exp u32 | nonce (16) | urlLen u16 | URL (UTF-8).
struct PasskeyEnvelope: Equatable {
  static let magic = Array("PKYWA1".utf8)
  static let version: UInt8 = 1
  static let nonceLength = 16
  static let headerLength = 6 + 1 + 1 + 4 + nonceLength + 2
  static let maxUrlLength = 4096

  let version: UInt8
  let flags: UInt8
  let exp: UInt32
  let nonce: Data
  let url: String

  static func hasMagic(_ bytes: Data) -> Bool {
    bytes.count >= magic.count && Array(bytes.prefix(magic.count)) == magic
  }

  static func decode(_ data: Data) -> PasskeyEnvelope? {
    let bytes = [UInt8](data)
    guard hasMagic(data), bytes.count >= headerLength, bytes[6] == version else { return nil }
    let exp = bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    let urlLength = Int(bytes[28]) << 8 | Int(bytes[29])
    guard urlLength <= maxUrlLength, bytes.count == headerLength + urlLength,
      let url = String(bytes: bytes[headerLength...], encoding: .utf8)
    else { return nil }
    return PasskeyEnvelope(
      version: bytes[6], flags: bytes[7], exp: exp, nonce: Data(bytes[12..<28]), url: url)
  }
}

enum Base64Url {
  static func encode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func decode(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return Data(base64Encoded: base64)
  }
}
