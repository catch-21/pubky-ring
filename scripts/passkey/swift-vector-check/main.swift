import Crypto
import Foundation

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func unhex(_ s: String) -> Data {
  var data = Data()
  var i = s.startIndex
  while i < s.endIndex {
    let j = s.index(i, offsetBy: 2)
    data.append(UInt8(s[i..<j], radix: 16)!)
    i = j
  }
  return data
}

var failures = 0
func check(_ name: String, _ ok: Bool) {
  print("\(ok ? "ok  " : "FAIL") \(name)")
  if !ok { failures += 1 }
}

let path = CommandLine.arguments[1]
let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
let env = vectors["envelope"] as! [String: Any]
let input = env["input"] as! [String: Any]
let bytes = unhex(env["hex"] as! String)

check("base64url decode matches hex", Base64Url.decode(env["base64url"] as! String) == bytes)
check("base64url encode matches", Base64Url.encode(bytes) == env["base64url"] as! String)
check("hasMagic", PasskeyEnvelope.hasMagic(bytes))
let decoded = PasskeyEnvelope.decode(bytes)
check("envelope decodes", decoded != nil)
if let decoded {
  check("envelope exp", UInt64(decoded.exp) == (input["exp"] as! NSNumber).uint64Value)
  check("envelope nonce", hex(decoded.nonce) == input["nonce"] as! String)
  check("envelope url", decoded.url == input["url"] as! String)
}
check("truncated envelope rejected", PasskeyEnvelope.decode(bytes.dropLast(1)) == nil)
var badMagic = bytes
badMagic[0] = 0
check("bad magic rejected", PasskeyEnvelope.decode(badMagic) == nil)

let rpId = "pubky-ring-demo.vercel.app"
let exp = UInt32((input["exp"] as! NSNumber).uint32Value)
func rejection(_ result: Result<PasskeyPolicy.Validated, PasskeyPolicy.Rejection>) -> String {
  switch result {
  case .success: return "ok"
  case .failure(let reason): return reason.rawValue
  }
}
check("valid envelope accepted", rejection(PasskeyPolicy.validate(envelopeBytes: bytes, rpId: rpId, now: exp - 60, hasSeenNonce: { _ in false })) == "ok")
check("caps parsed", (try? PasskeyPolicy.validate(envelopeBytes: bytes, rpId: rpId, now: exp - 60, hasSeenNonce: { _ in false }).get().link.capabilities) == "/pub/pubky.app/:rw")
check("expired", rejection(PasskeyPolicy.validate(envelopeBytes: bytes, rpId: rpId, now: exp + 31, hasSeenNonce: { _ in false })) == "expired")
check("within skew", rejection(PasskeyPolicy.validate(envelopeBytes: bytes, rpId: rpId, now: exp + 30, hasSeenNonce: { _ in false })) == "ok")
check("lifetime", rejection(PasskeyPolicy.validate(envelopeBytes: bytes, rpId: rpId, now: exp - 331, hasSeenNonce: { _ in false })) == "lifetime")
check("replayed", rejection(PasskeyPolicy.validate(envelopeBytes: bytes, rpId: rpId, now: exp - 60, hasSeenNonce: { _ in true })) == "replayed")
check("cid mismatch", rejection(PasskeyPolicy.validate(envelopeBytes: bytes, rpId: "evil.example", now: exp - 60, hasSeenNonce: { _ in false })) == "client_id_mismatch")
check("subdomain refused under exact", rejection(PasskeyPolicy.validate(envelopeBytes: bytes, rpId: "vercel.app", now: exp - 60, hasSeenNonce: { _ in false })) == "client_id_mismatch")
check("subdomain allowed under relaxed policy", rejection(PasskeyPolicy.validate(envelopeBytes: bytes, rpId: "vercel.app", now: exp - 60, hasSeenNonce: { _ in false }, policy: .subdomain)) == "ok")

let mailbox = vectors["mailbox"] as! [String: Any]
let prfInput = unhex(mailbox["prfInputHex"] as! String)
let salt = PasskeyMailbox.prfSalt(prfInput)
check("prf salt", hex(salt) == mailbox["prfSaltHex"] as! String)
let key = PasskeyMailbox.key(salt: salt).withUnsafeBytes { Data($0) }
check("mailbox key", hex(key) == mailbox["keyHex"] as! String)
check("mailbox channel", PasskeyMailbox.channel(salt: salt) == mailbox["channel"] as! String)
let opened = try? PasskeyMailbox.open(body: unhex(mailbox["bodyHex"] as! String), salt: salt, rpId: mailbox["rpId"] as! String)
check("mailbox opens to the envelope", opened == bytes)
check("mailbox bound to rpId", (try? PasskeyMailbox.open(body: unhex(mailbox["bodyHex"] as! String), salt: salt, rpId: "evil.example")) == nil)

let cred = vectors["credentialId"] as! [String: Any]
check("credential id", hex(PasskeyShared.credentialId(rpId: cred["rpId"] as! String, pubky: cred["pubky"] as! String)) == cred["hex"] as! String)

let ceremony = P256.Signing.PrivateKey()
let point = ceremony.publicKey.x963Representation
let cose = WebAuthnEncoding.coseKey(ceremony.publicKey)
let expectedCose = unhex("a5010203262001215820") + point.subdata(in: 1..<33) + unhex("225820") + point.subdata(in: 33..<65)
check("COSE key encoding", cose == expectedCose)
let credId = Data(repeating: 7, count: 16)
let attested = WebAuthnEncoding.attestedCredentialData(credentialId: credId, publicKey: ceremony.publicKey)
check("attested credential data", attested == Data(count: 16) + unhex("0010") + credId + expectedCose)
let authData = WebAuthnEncoding.authenticatorData(rpId: rpId, userVerified: true)
check("authenticator data", authData == Data(SHA256.hash(data: Data(rpId.utf8))) + unhex("0500000000"))
let regAuthData = WebAuthnEncoding.authenticatorData(rpId: rpId, userVerified: true, attestedCredentialData: attested)
check("registration flags", regAuthData[32] == 0x45)
let attestation = WebAuthnEncoding.noneAttestationObject(authData: regAuthData)
var expectedAttestation = unhex("a363666d74646e6f6e656761747453746d74a0686175746844617461")
expectedAttestation.append(regAuthData.count < 256 ? Data([0x58, UInt8(regAuthData.count)]) : Data([0x59, UInt8(regAuthData.count >> 8), UInt8(regAuthData.count & 0xff)]))
check("none attestation object", attestation == expectedAttestation + regAuthData)

print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
exit(failures == 0 ? 0 : 1)
