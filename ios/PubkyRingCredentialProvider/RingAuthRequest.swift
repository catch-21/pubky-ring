import Foundation

/// Twin of src/utils/authCapabilities.ts.
struct AuthCapability: Equatable {
  static let encryptionAction: Character = "e"

  let path: String
  let permission: String

  /// "/pub/pubky.app/:rw,/pub/other/:r" → [("/pub/pubky.app/", "rw"), ("/pub/other/", "r")]
  static func parse(_ caps: String?) -> [AuthCapability] {
    (caps ?? "").split(separator: ",").compactMap { entry in
      guard let colon = entry.lastIndex(of: ":") else { return nil }
      return AuthCapability(path: String(entry[..<colon]), permission: String(entry[colon...].dropFirst()))
    }
  }

  static func hasEncryption(_ capabilities: [AuthCapability]) -> Bool {
    capabilities.contains { $0.permission.contains(encryptionAction) }
  }

  /// Declining encryption keeps read/write access and drops scopes with no actions left.
  static func approved(_ capabilities: [AuthCapability], encryptionApproved: Bool) -> [AuthCapability] {
    capabilities
      .map {
        AuthCapability(
          path: $0.path,
          permission: encryptionApproved ? $0.permission : $0.permission.filter { $0 != encryptionAction })
      }
      .filter { !$0.permission.isEmpty }
  }

  static func serialise(_ capabilities: [AuthCapability]) -> String {
    capabilities.map { "\($0.path):\($0.permission)" }.joined(separator: ",")
  }
}

/// Twin of src/components/AuthSummary.tsx: the sentence at the top of the Authorize sheet.
enum AuthSummaryText {
  private static let accessLabels = ["r": "auth.readData", "w": "auth.editData", "rw": "auth.readAndEdit"]

  static func runs(
    capabilities: [AuthCapability], authorised: Bool, t: (String, [String: String]) -> String
  ) -> [RingTextRun] {
    let active = capabilities.filter { !$0.permission.isEmpty }
    if active.isEmpty {
      return [
        RingTextRun(text: t(authorised ? "auth.identitySuccessSummary" : "auth.identityRequestSummary", [:]), bold: false)
      ]
    }
    let encrypted = active.contains { $0.permission.contains(AuthCapability.encryptionAction) }
    let accessTypes = unique(active.map { capability in ["r", "w"].filter { capability.permission.contains($0) }.joined() })
    let scopes = unique(active.map { scope(of: $0.path) })
    let scopeList =
      scopes.count > 1
      ? t("auth.scopeList", ["scopes": scopes.dropLast().joined(separator: ", "), "last": scopes[scopes.count - 1]])
      : scopes[0]
    let allData = scopes.contains("/")
    let access = t(accessTypes.count == 1 ? accessLabels[accessTypes[0]] ?? "auth.accessData" : "auth.accessData", [:])
    let template = t(authorised ? "auth.dataSuccessSummary" : "auth.dataRequestSummary", ["access": access])
    return RingTrans.runs(template) { name, _ in
      switch name {
      case "data":
        if allData { return [RingTextRun(text: t("auth.allYourData", [:]), bold: false)] }
        return RingTrans.runs(t("auth.scopeData", [:])) { inner, _ in
          inner == "scope" ? [RingTextRun(text: scopeList, bold: true)] : []
        }
      case "encryption":
        guard encrypted else { return [] }
        return RingTrans.runs(t("auth.includingEncryptedData", [:])) { inner, children in
          inner == "bold" ? children.map { RingTextRun(text: $0.text, bold: true) } : []
        }
      default:
        return []
      }
    }
  }

  /// "/pub/pubky.app/…" → "pubky.app"; anything else is shown as its full path.
  static func scope(of path: String) -> String {
    for prefix in ["/pub/", "/priv/"] where path.hasPrefix(prefix) {
      let rest = path.dropFirst(prefix.count)
      if let slash = rest.firstIndex(of: "/"), slash > rest.startIndex {
        return String(rest[..<slash])
      }
    }
    return path
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
}

/// Twins of the display helpers in src/utils/pubky.ts and src/components/ProfileAvatar.tsx.
enum RingFormat {
  static func truncate(_ value: String, _ displayLength: Int = 5) -> String {
    let characters = Array(value.utf16)
    guard characters.count > displayLength * 2 else { return value }
    let head = String(decoding: characters.prefix(displayLength), as: UTF16.self)
    let tail = String(decoding: characters.suffix(displayLength), as: UTF16.self)
    return "\(head)...\(tail)"
  }

  static func truncatePubky(_ pubky: String) -> String {
    let result = truncate(pubky)
    return result.hasPrefix("pk:") ? String(result.dropFirst(3)) : result
  }

  static func avatarSeed(_ pubky: String) -> String {
    (pubky.hasPrefix("pk:") ? String(pubky.dropFirst(3)) : pubky).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func avatarInitial(name: String?, seed: String) -> String {
    let displayName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !displayName.isEmpty && !isDefaultName(displayName) {
      return String(displayName.prefix(1)).uppercased()
    }
    return String(seed.prefix(1)).uppercased()
  }

  /// /^pubky #\d+(?: \(Bitkit\))?$/i
  static func isDefaultName(_ name: String) -> Bool {
    let lower = name.lowercased()
    guard lower.hasPrefix("pubky #") else { return false }
    var rest = Substring(lower.dropFirst("pubky #".count))
    if rest.hasSuffix(" (bitkit)") { rest = rest.dropLast(" (bitkit)".count) }
    return !rest.isEmpty && rest.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
