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
let report = vectors["report"] as! [String: Any]
let reportNonce = unhex(report["nonceHex"] as! String)
check("report channel", PasskeyReport.channel(nonce: reportNonce) == report["channel"] as! String)
check("report body", String(decoding: PasskeyReport.body(reason: report["reason"] as! String), as: UTF8.self) == report["body"] as! String)
check("report url from the envelope's relay", PasskeyReport.url(envelopeBytes: bytes)?.absoluteString == "https://httprelay.staging.pubky.app/inbox/\(report["channel"] as! String)")
func envelopeWith(relay: String) -> Data {
  let url = "pubkyauth://signin_grant?relay=\(relay.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&cid=pubky.app"
  var data = Data("PKYWA1".utf8) + Data([1, 0]) + Data([0x70, 0xdb, 0xd8, 0x80]) + reportNonce
  data += Data([UInt8(url.utf8.count >> 8), UInt8(url.utf8.count & 0xff)]) + Data(url.utf8)
  return data
}
check("report url trims the relay's slashes", PasskeyReport.url(envelopeBytes: envelopeWith(relay: report["relay"] as! String))?.absoluteString == (report["url"] as! String))
check("no report to an http relay", PasskeyReport.url(envelopeBytes: envelopeWith(relay: "http://relay.example/inbox")) == nil)
check("no report to a relay with a query", PasskeyReport.url(envelopeBytes: envelopeWith(relay: "https://relay.example/inbox?x=1")) == nil)
check("no report without an envelope", PasskeyReport.url(envelopeBytes: Data("nope".utf8)) == nil)

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
check("authenticator data", authData == Data(SHA256.hash(data: Data(rpId.utf8))) + unhex("1d00000000"))
let regAuthData = WebAuthnEncoding.authenticatorData(rpId: rpId, userVerified: true, attestedCredentialData: attested)
check("registration flags", regAuthData[32] == 0x5d)
let attestation = WebAuthnEncoding.noneAttestationObject(authData: regAuthData)
var expectedAttestation = unhex("a363666d74646e6f6e656761747453746d74a0686175746844617461")
expectedAttestation.append(regAuthData.count < 256 ? Data([0x58, UInt8(regAuthData.count)]) : Data([0x59, UInt8(regAuthData.count >> 8), UInt8(regAuthData.count & 0xff)]))
check("none attestation object", attestation == expectedAttestation + regAuthData)

// Consent sheet: the extension's ports of Ring's i18n, AuthSummary, display helpers, icons and Facehash.
let locales = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("../../../src/i18n/locales")
let localeData = try ["en", "es"].reduce(into: [String: Data]()) {
  $0[$1] = try Data(contentsOf: locales.appendingPathComponent("\($1).json"))
}
let en = RingStringTable(tables: localeData, preferredLanguages: ["en-GB"])
let es = RingStringTable(tables: localeData, preferredLanguages: ["es-ES", "en"])
check("language from the first preferred language", es.language == "es")
check("unsupported language falls back to English", RingStringTable.language(preferredLanguages: ["fr-FR", "es"]) == "en")
check("underscore locale", RingStringTable.language(preferredLanguages: ["es_MX"]) == "es")
check("string lookup", en.t("auth.authorize") == "Authorize")
check("interpolation", en.t("auth.authorized", ["pubky": "abc"]) == "Authorized with: abc")
check("Spanish lookup", es.t("auth.showDetails") != en.t("auth.showDetails"))
check("missing key", en.t("auth.nope") == "auth.nope")
check("passkey rejection keys exist", ["malformed", "expired", "lifetime", "replayed", "unsupported_link", "insecure_relay", "client_id_mismatch", "origin_mismatch"].allSatisfy { en.t("passkey.errors.\($0)") != "passkey.errors.\($0)" && es.t("passkey.errors.\($0)") != "passkey.errors.\($0)" })
check("rejection raw values match the i18n keys", PasskeyPolicy.Rejection.unsupportedLink.rawValue == "unsupported_link")
for key in ["not_pubky_request", "no_pubkys", "request_not_found", "ios_too_old", "secret_unavailable"] {
  check("iOS error \(key) in en and es", en.t("passkey.errors.\(key)") != "passkey.errors.\(key)" && es.t("passkey.errors.\(key)") != en.t("passkey.errors.\(key)"))
}

func summary(_ table: RingStringTable, _ caps: [AuthCapability], authorised: Bool = false) -> (text: String, bold: [String]) {
  let runs = AuthSummaryText.runs(capabilities: caps, authorised: authorised, t: table.t)
  return (runs.map(\.text).joined(), runs.filter(\.bold).map(\.text))
}
let single = summary(en, [AuthCapability(path: "/pub/pubky.app/", permission: "rw")])
check("summary single scope", single.text == "A service is requesting permission to read and edit your pubky.app data.")
check("summary scope is bold", single.bold == ["pubky.app"])
let encryptedSummary = summary(en, [
  AuthCapability(path: "/pub/pubky.app/", permission: "rw"), AuthCapability(path: "/priv/pubky.app/", permission: "rwe"),
  AuthCapability(path: "/priv/paykit/", permission: "rwe"),
])
check("summary dedupes scopes and includes encryption", encryptedSummary.text == "A service is requesting permission to read and edit your pubky.app and paykit data, including encrypted data.")
check("summary bold runs", encryptedSummary.bold == ["pubky.app and paykit", "encrypted"])
check("summary mixed access", summary(en, [AuthCapability(path: "/pub/one/", permission: "r"), AuthCapability(path: "/pub/two/", permission: "w")]).text == "A service is requesting permission to access your one and two data.")
check("summary root", summary(en, [AuthCapability(path: "/", permission: "rw")]).text == "A service is requesting permission to read and edit all your data.")
check("summary success", summary(en, [AuthCapability(path: "/pub/pubky.app/", permission: "r")], authorised: true).text == "You gave the service permission to read your pubky.app data.")
check("summary identity success", summary(en, [], authorised: true).text == "You gave the service permission to verify your pubky identity.")
check("summary identity request", summary(en, [AuthCapability(path: "/pub/x/", permission: "")]).text == en.t("auth.identityRequestSummary"))
check("summary Spanish ordering", summary(es, [AuthCapability(path: "/priv/pubky.app/", permission: "rwe")]).text == "Un servicio solicita permiso para leer y editar tus datos de pubky.app, incluidos los datos cifrados.")

let caps = AuthCapability.parse("/priv/chat/:rwe,/priv/keys/:e,/pub/pubky.app/:rw")
check("capabilities parse", caps == [AuthCapability(path: "/priv/chat/", permission: "rwe"), AuthCapability(path: "/priv/keys/", permission: "e"), AuthCapability(path: "/pub/pubky.app/", permission: "rw")])
check("encryption detected", AuthCapability.hasEncryption(caps))
check("declining encryption", AuthCapability.serialise(AuthCapability.approved(caps, encryptionApproved: false)) == "/priv/chat/:rw,/pub/pubky.app/:rw")
check("approving encryption", AuthCapability.serialise(AuthCapability.approved(caps, encryptionApproved: true)) == "/priv/chat/:rwe,/priv/keys/:e,/pub/pubky.app/:rw")

check("truncatePubky z32", RingFormat.truncatePubky("abcdefghijklmnop") == "abcde...lmnop")
check("truncatePubky pk: prefix", RingFormat.truncatePubky("pk:abcdefghijklmnop") == "ab...lmnop")
check("truncatePubky short", RingFormat.truncatePubky("pk:abc") == "abc")
check("name truncation", RingFormat.truncate("A long pubky name", 8) == "A long p...bky name")
check("default names", RingFormat.isDefaultName("pubky #3") && RingFormat.isDefaultName("Pubky #12 (Bitkit)"))
check("not default names", !RingFormat.isDefaultName("pubky #") && !RingFormat.isDefaultName("pubky #3x") && !RingFormat.isDefaultName("Alice"))
check("avatar initial from name", RingFormat.avatarInitial(name: " alice", seed: "xyz") == "A")
check("avatar initial from seed", RingFormat.avatarInitial(name: "pubky #2", seed: "xyz") == "X" && RingFormat.avatarInitial(name: "", seed: "xyz") == "X")
check("avatar seed", RingFormat.avatarSeed("pk:abc ") == "abc")

let faces: [(String, Int, RingFacehash.FaceType, Int, RingPoint, RingPoint)] = [
  ("8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo", 1427496531, .curved, 3, RingPoint(x: 0, y: -1), RingPoint(x: 56, y: 50)),
  ("o1gg96ewuojmopcjbz8895478wdtxtzzuxnfjjz8o8e77csa1ngo", 1455527243, .curved, 5, RingPoint(x: 1, y: 0), RingPoint(x: 50, y: 56)),
  ("a", 97, .cross, 1, RingPoint(x: -1, y: -1), RingPoint(x: 56, y: 44)),
  ("", 0, .round, 0, RingPoint(x: -1, y: 1), RingPoint(x: 44, y: 44)),
]
for (seed, hash, face, colour, rotation, gradient) in faces {
  let facehash = RingFacehash(seed: seed, colourCount: 6)
  check("facehash \(seed.prefix(6)) matches react-native-facehash", facehash.hash == hash && facehash.faceType == face && facehash.colourIndex == colour && facehash.rotation == rotation && facehash.gradientCentre == gradient)
}
check("facehash hash wraps like JS", RingFacehash.stringHash(String(repeating: "z", count: 64)) >= 0)
let crossTransform = RingFacehash(seed: "a", colourCount: 6).transform
let close = { (p: RingPoint, x: Double, y: Double) in abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9 }
check("facehash transform origin", close(crossTransform.apply(RingPoint(x: 0, y: 0)), 16.173225314884178, 34.94241119661852))
check("facehash transform corner", close(crossTransform.apply(RingPoint(x: 71, y: 23)), 72.36376481111625, 51.13758880338149))
check("single colour palette", RingFacehash(seed: "a", colourCount: 1).colourIndex == 0)

check("path parse", RingSVGPath.parse("M2 12h20") == [.move(RingPoint(x: 2, y: 12)), .line(RingPoint(x: 22, y: 12))])
check("relative path parse", RingSVGPath.parse("m12 19-7-7 7-7") == [.move(RingPoint(x: 12, y: 19)), .line(RingPoint(x: 5, y: 12)), .line(RingPoint(x: 12, y: 5))])
func endPoint(_ commands: [RingPathCommand]) -> RingPoint? {
  var point: RingPoint?
  for command in commands {
    switch command {
    case .move(let p), .line(let p), .quad(_, let p), .cubic(_, _, let p): point = p
    case .close: break
    }
  }
  return point
}
if let end = endPoint(RingSVGPath.parse("M2.062 12.348a1 1 0 0 1 0-.696")) {
  check("compact arc numbers", close(end, 2.062, 11.652))
}
if case .cubic(_, _, let mid)? = RingSVGPath.parse("M0 0A10 10 0 0 1 20 0").last {
  check("arc end point", close(mid, 20, 0))
}
let quarter = RingSVGPath.arc(from: RingPoint(x: 10, y: 0), to: RingPoint(x: 0, y: 10), rx: 10, ry: 10, rotation: 0, largeArc: false, sweep: true)
if case .cubic(let c1, let c2, _)? = quarter.first {
  check("quarter arc is one cubic with the standard handle", quarter.count == 1 && close(c1, 10, 5.5228474983079) && close(c2, 5.5228474983079, 10))
}
for icon in RingIcon.allCases {
  let all = icon.paths.stroke.map(RingSVGPath.parse)
  let inside = all.allSatisfy { commands in
    !commands.isEmpty && commands.allSatisfy { command in
      switch command {
      case .move(let p), .line(let p), .quad(_, let p), .cubic(_, _, let p): return (0...24).contains(p.x) && (0...24).contains(p.y)
      case .close: return true
      }
    }
  }
  check("icon \(icon) parses inside its 24×24 box", inside)
}
let arrow = RingSVGPath.parse(RingSwipeArrow.path)
check("swipe arrow parses", arrow.count > 20 && arrow.last == .close)
for face in RingFacehash.FaceType.allCases {
  var facehash = RingFacehash(seed: "", colourCount: 6)
  for seed in ["", "a", "b", "c", "d", "e", "f", "g"] where RingFacehash(seed: seed, colourCount: 6).faceType == face {
    facehash = RingFacehash(seed: seed, colourCount: 6)
  }
  let eyes = (facehash.geometry.leftEye + facehash.geometry.rightEye).map(RingSVGPath.parse)
  check("face \(face) eyes parse", facehash.faceType != face || eyes.allSatisfy { $0.count > 3 && $0.last == .close })
}

check("sheet drag begins downwards", RingSheetDrag.shouldBegin(translationX: 3, translationY: 12, scrollAtTop: true))
check("sheet drag leaves the horizontal swipe alone", !RingSheetDrag.shouldBegin(translationX: 14, translationY: 10, scrollAtTop: true))
check("sheet drag ignores upward drags", !RingSheetDrag.shouldBegin(translationX: 0, translationY: -12, scrollAtTop: true))
check("sheet drag waits for the scroll top", !RingSheetDrag.shouldBegin(translationX: 0, translationY: 12, scrollAtTop: false))
check("sheet drag dismisses past a quarter", RingSheetDrag.shouldDismiss(translationY: 201, velocityY: 0, height: 800))
check("sheet drag springs back short of a quarter", !RingSheetDrag.shouldDismiss(translationY: 199, velocityY: 0, height: 800))
check("sheet drag dismisses on a fling", RingSheetDrag.shouldDismiss(translationY: 40, velocityY: 1200, height: 800))
check("sheet drag ignores an upward fling", !RingSheetDrag.shouldDismiss(translationY: 0, velocityY: 1200, height: 800))

print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
exit(failures == 0 ? 0 : 1)
