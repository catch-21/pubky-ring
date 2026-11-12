import Foundation

/// Ring's i18n strings (src/i18n/locales/*.json, bundled into the extension) so the consent sheet
/// reads exactly as the app does. Keys and {{value}} interpolation follow i18next.
struct RingStringTable {
  static let supportedLanguages = ["en", "es"]
  static let fallbackLanguage = "en"

  let language: String
  private let tables: [String: [String: Any]]

  init(tables data: [String: Data], preferredLanguages: [String]) {
    var tables: [String: [String: Any]] = [:]
    for (language, json) in data {
      if let table = try? JSONSerialization.jsonObject(with: json) as? [String: Any] {
        tables[language] = table
      }
    }
    self.tables = tables
    language = Self.language(preferredLanguages: preferredLanguages)
  }

  /// Same rule as getDeviceLanguage in src/i18n/index.ts: the first preferred language if Ring has it.
  static func language(preferredLanguages: [String]) -> String {
    guard let first = preferredLanguages.first,
      let code = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map({ $0.lowercased() }),
      supportedLanguages.contains(code)
    else { return fallbackLanguage }
    return code
  }

  func t(_ key: String, _ values: [String: String] = [:]) -> String {
    let template =
      Self.lookup(key, in: tables[language]) ?? Self.lookup(key, in: tables[Self.fallbackLanguage]) ?? key
    return values.reduce(template) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
  }

  private static func lookup(_ key: String, in table: [String: Any]?) -> String? {
    var node: Any? = table
    for part in key.split(separator: ".") {
      node = (node as? [String: Any])?[String(part)]
    }
    return node as? String
  }
}

enum RingStrings {
  static let shared: RingStringTable = {
    var data: [String: Data] = [:]
    for language in RingStringTable.supportedLanguages {
      if let url = Bundle.main.url(forResource: language, withExtension: "json"),
        let json = try? Data(contentsOf: url)
      {
        data[language] = json
      }
    }
    return RingStringTable(tables: data, preferredLanguages: Locale.preferredLanguages)
  }()

  static func t(_ key: String, _ values: [String: String] = [:]) -> String {
    shared.t(key, values)
  }
}

/// One run of a translated sentence; `bold` runs are the <bold>/<scope> parts of react-i18next's Trans.
struct RingTextRun: Equatable {
  let text: String
  let bold: Bool
}

enum RingTrans {
  /// Expands Trans markup: `<name/>` and `<name>inner</name>` are replaced by `component(name, innerRuns)`.
  static func runs(_ template: String, component: (String, [RingTextRun]) -> [RingTextRun]) -> [RingTextRun] {
    var result: [RingTextRun] = []
    var rest = Substring(template)
    while let open = rest.firstIndex(of: "<") {
      if open > rest.startIndex { result.append(RingTextRun(text: String(rest[..<open]), bold: false)) }
      guard let close = rest[open...].firstIndex(of: ">") else {
        rest = rest[open...]
        break
      }
      let tag = rest[rest.index(after: open)..<close]
      if tag.hasSuffix("/") {
        result += component(String(tag.dropLast()), [])
        rest = rest[rest.index(after: close)...]
        continue
      }
      let closing = "</\(tag)>"
      guard let end = rest[close...].range(of: closing) else {
        result.append(RingTextRun(text: String(rest[open...close]), bold: false))
        rest = rest[rest.index(after: close)...]
        continue
      }
      let inner = runs(String(rest[rest.index(after: close)..<end.lowerBound]), component: component)
      result += component(String(tag), inner)
      rest = rest[end.upperBound...]
    }
    if !rest.isEmpty { result.append(RingTextRun(text: String(rest), bold: false)) }
    return result
  }
}
