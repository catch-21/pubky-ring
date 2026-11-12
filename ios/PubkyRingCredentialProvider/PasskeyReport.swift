import CryptoKit
import Foundation

/// Tells the page why Ring refused a request, since Safari only ever gives it NotAllowedError. Ring
/// posts {"v":1,"reason":…} to the request's own relay, on a channel derived from the envelope nonce,
/// and the page reads it once the ceremony fails. Best effort, and separate from the grant and the
/// assertion. Twin of src/passkey/report.ts and scripts/passkey/protocol-reference.js.
enum PasskeyReport {
  static let channelLabel = "pubky-ring-webauthn-report-v1/channel"
  static let timeout: TimeInterval = 3

  static func channel(nonce: Data) -> String {
    var data = Data(channelLabel.utf8)
    data.append(nonce)
    return Base64Url.encode(Data(SHA256.hash(data: data)))
  }

  /// Reasons are fixed snake_case codes, so they need no JSON escaping.
  static func body(reason: String) -> Data { Data("{\"v\":1,\"reason\":\"\(reason)\"}".utf8) }

  /// Only to an https relay named by the envelope's link.
  static func url(envelopeBytes: Data) -> URL? {
    guard let envelope = PasskeyEnvelope.decode(envelopeBytes),
      let relay = PasskeyPolicy.parseLink(envelope.url)?.relay,
      relay.lowercased().hasPrefix("https://"), !relay.contains("?"), !relay.contains("#")
    else { return nil }
    var base = Substring(relay)
    while base.hasSuffix("/") { base = base.dropLast() }
    return URL(string: "\(base)/\(channel(nonce: envelope.nonce))")
  }

  static func post(reason: String, envelopeBytes: Data) async {
    guard let url = url(envelopeBytes: envelopeBytes) else { return }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body(reason: reason)
    _ = try? await URLSession.shared.data(for: request)
  }
}
