import Foundation

/// Twin of src/passkey/policy.ts. Keep the two in step; the shared vectors in
/// __tests__/fixtures/passkey/vectors.json cover both.
enum ClientIdPolicy {
  /// cid must equal the rpId (PLAN.md section 14, decision 4).
  case exact
  /// Also accept subdomains of the rpId, for example cid staging.pubky.app at rpId pubky.app.
  case subdomain
}

enum PasskeyPolicy {
  static let clientIdPolicy: ClientIdPolicy = .exact
  static let maxLifetimeSeconds: UInt32 = 300
  static let clockSkewSeconds: UInt32 = 30

  enum Rejection: String, Error {
    case malformed, expired, lifetime, replayed
    case unsupportedLink = "unsupported_link"
    case insecureRelay = "insecure_relay"
    case clientIdMismatch = "client_id_mismatch"
    case originMismatch = "origin_mismatch"
  }

  struct Link {
    let route: String
    let clientId: String?
    let relay: String?
    let approvalFormat: String?
    let ephemeralPublicKey: String?
    let clientPublicKey: String?
    let hasSecret: Bool
    let capabilities: String?
  }

  struct Validated {
    let envelope: PasskeyEnvelope
    let link: Link
  }

  static func normalise(_ host: String) -> String {
    var value = host.trimmingCharacters(in: .whitespaces).lowercased()
    if value.hasSuffix(".") { value.removeLast() }
    return value
  }

  static func isHostAllowed(_ host: String, rpId: String, policy: ClientIdPolicy = clientIdPolicy) -> Bool {
    let candidate = normalise(host)
    let expected = normalise(rpId)
    guard !candidate.isEmpty, !expected.isEmpty else { return false }
    if candidate == expected { return true }
    return policy == .subdomain && candidate.hasSuffix(".\(expected)")
  }

  static func parseLink(_ url: String) -> Link? {
    guard url.hasPrefix("pubkyauth://"), let query = url.firstIndex(of: "?") else { return nil }
    var route = String(url[url.index(url.startIndex, offsetBy: "pubkyauth://".count)..<query])
    if route.hasSuffix("/") { route.removeLast() }
    guard route.allSatisfy({ $0 == "_" || ("a"..."z").contains($0) }) else { return nil }
    var params: [String: String] = [:]
    for pair in url[url.index(after: query)...].split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let decode = { (raw: Substring) in raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
      guard let key = decode(parts[0]), let value = decode(parts.count > 1 ? parts[1] : "") else { return nil }
      params[key] = value
    }
    return Link(
      route: route, clientId: params["cid"], relay: params["relay"], approvalFormat: params["af"],
      ephemeralPublicKey: params["epk"], clientPublicKey: params["cpk"], hasSecret: params["secret"] != nil,
      capabilities: params["caps"])
  }

  static func validate(
    envelopeBytes: Data, rpId: String, now: UInt32, hasSeenNonce: (Data) -> Bool,
    policy: ClientIdPolicy = clientIdPolicy
  ) -> Result<Validated, Rejection> {
    guard let envelope = PasskeyEnvelope.decode(envelopeBytes) else { return .failure(.malformed) }
    if UInt64(envelope.exp) + UInt64(clockSkewSeconds) < UInt64(now) { return .failure(.expired) }
    if UInt64(envelope.exp) > UInt64(now) + UInt64(maxLifetimeSeconds + clockSkewSeconds) {
      return .failure(.lifetime)
    }
    if hasSeenNonce(envelope.nonce) { return .failure(.replayed) }
    guard let link = parseLink(envelope.url) else { return .failure(.malformed) }
    guard link.route == "signin_grant", link.approvalFormat == "v1", link.ephemeralPublicKey?.isEmpty == false,
      link.clientPublicKey?.isEmpty == false, !link.hasSecret
    else { return .failure(.unsupportedLink) }
    guard let relay = link.relay, relay.lowercased().hasPrefix("https://") else { return .failure(.insecureRelay) }
    guard let clientId = link.clientId, isHostAllowed(clientId, rpId: rpId, policy: policy) else {
      return .failure(.clientIdMismatch)
    }
    return .success(Validated(envelope: envelope, link: link))
  }
}
