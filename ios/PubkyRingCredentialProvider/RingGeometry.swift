import Foundation

/// Vector drawing for the extension's Ring icons and avatars, kept free of UIKit and SwiftUI so it can
/// be checked on any platform (scripts/passkey/swift-vector-check).
struct RingPoint: Equatable {
  var x: Double
  var y: Double
}

enum RingPathCommand: Equatable {
  case move(RingPoint)
  case line(RingPoint)
  case quad(RingPoint, RingPoint)
  case cubic(RingPoint, RingPoint, RingPoint)
  case close
}

/// A 2D affine transform in SVG's matrix(a b c d e f) form.
struct RingAffine: Equatable {
  var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

  static let identity = RingAffine()

  static func translate(_ x: Double, _ y: Double) -> RingAffine { RingAffine(e: x, f: y) }
  static func scale(_ x: Double, _ y: Double) -> RingAffine { RingAffine(a: x, d: y) }
  static func skewX(degrees: Double) -> RingAffine { RingAffine(c: tan(degrees * .pi / 180)) }
  static func skewY(degrees: Double) -> RingAffine { RingAffine(b: tan(degrees * .pi / 180)) }

  /// `lhs * rhs` applies `rhs` first, as in an SVG transform list.
  static func * (lhs: RingAffine, rhs: RingAffine) -> RingAffine {
    RingAffine(
      a: lhs.a * rhs.a + lhs.c * rhs.b, b: lhs.b * rhs.a + lhs.d * rhs.b,
      c: lhs.a * rhs.c + lhs.c * rhs.d, d: lhs.b * rhs.c + lhs.d * rhs.d,
      e: lhs.a * rhs.e + lhs.c * rhs.f + lhs.e, f: lhs.b * rhs.e + lhs.d * rhs.f + lhs.f)
  }

  func apply(_ point: RingPoint) -> RingPoint {
    RingPoint(x: a * point.x + c * point.y + e, y: b * point.x + d * point.y + f)
  }

  func apply(_ commands: [RingPathCommand]) -> [RingPathCommand] {
    commands.map { command in
      switch command {
      case .move(let p): return .move(apply(p))
      case .line(let p): return .line(apply(p))
      case .quad(let c1, let p): return .quad(apply(c1), apply(p))
      case .cubic(let c1, let c2, let p): return .cubic(apply(c1), apply(c2), apply(p))
      case .close: return .close
      }
    }
  }
}

/// Parses SVG path data (all commands, arcs converted to cubic Béziers).
enum RingSVGPath {
  static func parse(_ data: String) -> [RingPathCommand] {
    var scanner = Scanner(data)
    var commands: [RingPathCommand] = []
    var current = RingPoint(x: 0, y: 0)
    var start = current
    var lastControl: RingPoint?
    var lastCommand: Character = " "
    var command: Character?

    while true {
      scanner.skipSeparators()
      if let letter = scanner.letter() {
        command = letter
      } else if command == nil || scanner.isAtEnd {
        break
      }
      guard let active = command else { break }
      let relative = active.isLowercase
      let upper = Character(active.uppercased())
      func point(_ x: Double, _ y: Double) -> RingPoint {
        relative ? RingPoint(x: current.x + x, y: current.y + y) : RingPoint(x: x, y: y)
      }
      func reflected() -> RingPoint {
        guard let control = lastControl else { return current }
        return RingPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
      }
      var control: RingPoint?
      switch upper {
      case "Z":
        commands.append(.close)
        current = start
        command = nil
      case "M":
        guard let x = scanner.number(), let y = scanner.number() else { return commands }
        current = point(x, y)
        start = current
        commands.append(.move(current))
        command = relative ? "l" : "L"
      case "L":
        guard let x = scanner.number(), let y = scanner.number() else { return commands }
        current = point(x, y)
        commands.append(.line(current))
      case "H":
        guard let x = scanner.number() else { return commands }
        current = RingPoint(x: relative ? current.x + x : x, y: current.y)
        commands.append(.line(current))
      case "V":
        guard let y = scanner.number() else { return commands }
        current = RingPoint(x: current.x, y: relative ? current.y + y : y)
        commands.append(.line(current))
      case "C", "S":
        var c1: RingPoint
        if upper == "C" {
          guard let x1 = scanner.number(), let y1 = scanner.number() else { return commands }
          c1 = point(x1, y1)
        } else {
          c1 = "CS".contains(Character(lastCommand.uppercased())) ? reflected() : current
        }
        guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number()
        else { return commands }
        let c2 = point(x2, y2)
        current = point(x, y)
        commands.append(.cubic(c1, c2, current))
        control = c2
      case "Q", "T":
        var c1: RingPoint
        if upper == "Q" {
          guard let x1 = scanner.number(), let y1 = scanner.number() else { return commands }
          c1 = point(x1, y1)
        } else {
          c1 = "QT".contains(Character(lastCommand.uppercased())) ? reflected() : current
        }
        guard let x = scanner.number(), let y = scanner.number() else { return commands }
        current = point(x, y)
        commands.append(.quad(c1, current))
        control = c1
      case "A":
        guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
          let largeArc = scanner.flag(), let sweep = scanner.flag(), let x = scanner.number(), let y = scanner.number()
        else { return commands }
        let end = point(x, y)
        commands += arc(
          from: current, to: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
        current = end
      default:
        return commands
      }
      lastControl = control
      lastCommand = active
    }
    return commands
  }

  /// SVG 1.1 implementation notes F.6.5–F.6.6, then one cubic per quarter turn or less.
  static func arc(
    from p0: RingPoint, to p1: RingPoint, rx rxIn: Double, ry ryIn: Double, rotation: Double, largeArc: Bool,
    sweep: Bool
  ) -> [RingPathCommand] {
    if p0 == p1 { return [] }
    var rx = abs(rxIn)
    var ry = abs(ryIn)
    if rx == 0 || ry == 0 { return [.line(p1)] }
    let phi = rotation * .pi / 180
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2
    let dy = (p0.y - p1.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 {
      rx *= lambda.squareRoot()
      ry *= lambda.squareRoot()
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var factor = denominator == 0 ? 0 : (max(0, numerator) / denominator).squareRoot()
    if largeArc == sweep { factor = -factor }
    let cx1 = factor * rx * y1 / ry
    let cy1 = -factor * ry * x1 / rx
    let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
    let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
    func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
      atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi }
    if sweep && delta < 0 { delta += 2 * .pi }

    let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
    let step = delta / Double(segments)
    let k = 4.0 / 3.0 * tan(step / 4)
    func onEllipse(_ t: Double) -> RingPoint {
      RingPoint(
        x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
    }
    func derivative(_ t: Double) -> RingPoint {
      RingPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
    }
    var commands: [RingPathCommand] = []
    var t = theta1
    var from = p0
    for index in 0..<segments {
      let next = t + step
      let d0 = derivative(t)
      let d1 = derivative(next)
      let to = index == segments - 1 ? p1 : onEllipse(next)
      commands.append(
        .cubic(
          RingPoint(x: from.x + k * d0.x, y: from.y + k * d0.y), RingPoint(x: to.x - k * d1.x, y: to.y - k * d1.y),
          to))
      from = to
      t = next
    }
    return commands
  }

  private struct Scanner {
    let characters: [Character]
    var index = 0

    init(_ data: String) { characters = Array(data) }

    var isAtEnd: Bool { index >= characters.count }

    mutating func skipSeparators() {
      while index < characters.count, characters[index] == " " || characters[index] == ","
        || characters[index].isNewline || characters[index] == "\t"
      {
        index += 1
      }
    }

    mutating func letter() -> Character? {
      guard index < characters.count, characters[index].isLetter, characters[index] != "e",
        characters[index] != "E"
      else { return nil }
      defer { index += 1 }
      return characters[index]
    }

    mutating func flag() -> Bool? {
      skipSeparators()
      guard index < characters.count, characters[index] == "0" || characters[index] == "1" else { return nil }
      defer { index += 1 }
      return characters[index] == "1"
    }

    mutating func number() -> Double? {
      skipSeparators()
      let begin = index
      if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
      var seenDot = false
      var seenDigit = false
      while index < characters.count {
        let character = characters[index]
        if character.isASCII && character.isNumber {
          seenDigit = true
        } else if character == "." && !seenDot {
          seenDot = true
        } else {
          break
        }
        index += 1
      }
      if seenDigit, index < characters.count, characters[index] == "e" || characters[index] == "E" {
        var lookahead = index + 1
        if lookahead < characters.count, characters[lookahead] == "-" || characters[lookahead] == "+" {
          lookahead += 1
        }
        if lookahead < characters.count, characters[lookahead].isASCII, characters[lookahead].isNumber {
          index = lookahead
          while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
        }
      }
      guard seenDigit, let value = Double(String(characters[begin..<index])) else {
        index = begin
        return nil
      }
      return value
    }
  }
}

/// The Lucide icons Ring's Authorize sheet uses (lucide-react-native 1.28, 24×24, stroke 2, round caps).
enum RingIcon: CaseIterable {
  case arrowLeft, eye, folder, globe, keyRound, list, lock, pencil, shield, userRoundCheck

  /// Stroked outlines, plus any shapes Lucide fills with currentColor.
  var paths: (stroke: [String], fill: [String]) {
    switch self {
    case .arrowLeft: return (["m12 19-7-7 7-7", "M19 12H5"], [])
    case .eye:
      return (
        [
          "M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0",
          Self.circle(12, 12, 3),
        ], []
      )
    case .folder:
      return (
        [
          "M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"
        ], []
      )
    case .globe:
      return ([Self.circle(12, 12, 10), "M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20", "M2 12h20"], [])
    case .keyRound:
      return (
        [
          "M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z",
          Self.circle(16.5, 7.5, 0.5),
        ], [Self.circle(16.5, 7.5, 0.5)]
      )
    case .list: return (["M3 5h.01", "M3 12h.01", "M3 19h.01", "M8 5h13", "M8 12h13", "M8 19h13"], [])
    case .lock: return ([Self.roundedRect(x: 3, y: 11, width: 18, height: 11, radius: 2), "M7 11V7a5 5 0 0 1 10 0v4"], [])
    case .pencil:
      return (
        [
          "M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z",
          "m15 5 4 4",
        ], []
      )
    case .shield:
      return (
        [
          "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"
        ], []
      )
    case .userRoundCheck: return (["M2 21a8 8 0 0 1 13.292-6", Self.circle(10, 8, 5), "m16 19 2 2 4-4"], [])
    }
  }

  private static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> String {
    "M\(cx - r) \(cy)a\(r) \(r) 0 1 0 \(2 * r) 0a\(r) \(r) 0 1 0 \(-2 * r) 0Z"
  }

  private static func roundedRect(x: Double, y: Double, width: Double, height: Double, radius r: Double) -> String {
    "M\(x + r) \(y)H\(x + width - r)a\(r) \(r) 0 0 1 \(r) \(r)V\(y + height - r)a\(r) \(r) 0 0 1 \(-r) \(r)"
      + "H\(x + r)a\(r) \(r) 0 0 1 \(-r) \(-r)V\(y + r)a\(r) \(r) 0 0 1 \(r) \(-r)Z"
  }
}

/// src/images/swipe-arrow.svg: a downward arrow (24×24, fill #101010) that SwipeToConfirm turns -90°.
enum RingSwipeArrow {
  static let path =
    "M12 1.47656C11.3906 1.47656 10.957 1.89844 10.957 2.50781V17.9414L11.0508 20.4492L7.53516 16.5938L4.86328 13.9688C4.6875 13.7812 4.40625 13.6875 4.125 13.6875C3.53906 13.6875 3.11719 14.1328 3.11719 14.707C3.11719 14.9883 3.22266 15.2344 3.44531 15.4688L11.2148 23.2617C11.4375 23.4961 11.707 23.6133 12 23.6133C12.293 23.6133 12.5625 23.4961 12.7852 23.2617L20.5664 15.4688C20.7891 15.2344 20.8828 14.9883 20.8828 14.707C20.8828 14.1328 20.4609 13.6875 19.875 13.6875C19.5938 13.6875 19.3242 13.7812 19.1367 13.9688L16.4648 16.5938L12.9609 20.4375L13.043 17.9414V2.50781C13.043 1.89844 12.6094 1.47656 12 1.47656Z"
}

/// Port of react-native-facehash 0.3.3 as ProfileAvatar renders it: gradient variant, "dramatic" 3D,
/// circle shape, no initial in the SVG (ProfileAvatar draws its own mouth).
struct RingFacehash {
  enum FaceType: Int, CaseIterable { case round, cross, line, curved }

  private static let spherePositions: [(x: Double, y: Double)] = [
    (-1, 1), (1, 1), (1, 0), (0, 1), (-1, 0), (0, 0), (0, -1), (-1, -1), (1, -1),
  ]
  private static let faceWidth = 60.0
  private static let faceCentreY = 37.0
  private static let preset = (translate: 5.0, compress: 0.08, skewX: 3.5, skewY: 1.75, gradientShift: 6.0)

  let hash: Int
  let faceType: FaceType
  let colourIndex: Int
  let rotation: RingPoint

  init(seed: String, colourCount: Int) {
    hash = Self.stringHash(seed)
    faceType = FaceType(rawValue: hash % FaceType.allCases.count) ?? .round
    colourIndex = hash % max(colourCount, 1)
    let position = Self.spherePositions[hash % Self.spherePositions.count]
    rotation = RingPoint(x: position.x, y: position.y)
  }

  /// stringHash in react-native-facehash: Java-style 31× rolling hash over UTF-16 units, as Int32.
  static func stringHash(_ value: String) -> Int {
    var hash: Int32 = 0
    for unit in value.utf16 {
      hash = (hash &<< 5) &- hash &+ Int32(unit)
    }
    return Int(Int64(hash).magnitude)
  }

  /// Gradient centre in the 100×100 avatar box.
  var gradientCentre: RingPoint {
    RingPoint(x: 50 - rotation.y * Self.preset.gradientShift, y: 50 + rotation.x * Self.preset.gradientShift)
  }

  var geometry: (width: Double, height: Double, leftEye: [String], rightEye: [String]) {
    Self.geometries[faceType.rawValue]
  }

  /// Maps the face's own viewBox into the 100×100 avatar box (the SVG's two nested <G> transforms).
  var transform: RingAffine {
    let p = Self.preset
    let fixed = { (value: Double) in (value * 1000).rounded() / 1000 }
    let translateX = fixed(rotation.y * p.translate)
    let translateY = fixed(rotation.x * -p.translate)
    let scaleX = fixed(1 - abs(rotation.y) * p.compress)
    let scaleY = fixed(1 - abs(rotation.x) * p.compress)
    let skewX = fixed(rotation.x * -p.skewX)
    let skewY = fixed(rotation.y * p.skewY)
    let centre = RingAffine.translate(translateX, translateY) * RingAffine.translate(50, 50)
    let skew = RingAffine.skewX(degrees: skewX) * RingAffine.skewY(degrees: skewY)
    let projection = centre * skew * RingAffine.scale(scaleX, scaleY) * RingAffine.translate(-50, -50)
    let (width, height, _, _) = geometry
    let faceHeight = Self.faceWidth / (width / max(height, 1))
    let faceBox =
      RingAffine.translate(50 - Self.faceWidth / 2, Self.faceCentreY - faceHeight / 2)
      * RingAffine.scale(Self.faceWidth / width, faceHeight / height)
    return projection * faceBox
  }

  private static let geometries: [(width: Double, height: Double, leftEye: [String], rightEye: [String])] = [
    (
      63, 15,
      [
        "M14.4 7.2C14.4 11.1765 11.1765 14.4 7.2 14.4C3.22355 14.4 0 11.1765 0 7.2C0 3.22355 3.22355 0 7.2 0C11.1765 0 14.4 3.22355 14.4 7.2Z"
      ],
      [
        "M62.4 7.2C62.4 11.1765 59.1765 14.4 55.2 14.4C51.2236 14.4 48 11.1765 48 7.2C48 3.22355 51.2236 0 55.2 0C59.1765 0 62.4 3.22355 62.4 7.2Z"
      ]
    ),
    (
      71, 23,
      [
        "M11.5 0C12.9411 0 13.6619 0.000460386 14.1748 0.354492C14.3742 0.49213 14.547 0.664882 14.6846 0.864258C15.0384 1.37711 15.0391 2.09739 15.0391 3.53809V7.96094H19.4619C20.9027 7.96094 21.6229 7.9615 22.1357 8.31543C22.3352 8.45308 22.5079 8.62578 22.6455 8.8252C22.9995 9.3381 23 10.0589 23 11.5C23 12.9408 22.9995 13.661 22.6455 14.1738C22.5079 14.3733 22.3352 14.5459 22.1357 14.6836C21.6229 15.0375 20.9027 15.0381 19.4619 15.0381H15.0391V19.4619C15.0391 20.9026 15.0384 21.6229 14.6846 22.1357C14.547 22.3351 14.3742 22.5079 14.1748 22.6455C13.6619 22.9995 12.9411 23 11.5 23C10.0592 23 9.33903 22.9994 8.82617 22.6455C8.62674 22.5079 8.45309 22.3352 8.31543 22.1357C7.96175 21.6229 7.96191 20.9024 7.96191 19.4619V15.0381H3.53809C2.0973 15.0381 1.37711 15.0375 0.864258 14.6836C0.664834 14.5459 0.492147 14.3733 0.354492 14.1738C0.000498831 13.661 -5.88036e-08 12.9408 0 11.5C6.2999e-08 10.0589 0.000460356 9.3381 0.354492 8.8252C0.492144 8.62578 0.664842 8.45308 0.864258 8.31543C1.37711 7.9615 2.09731 7.96094 3.53809 7.96094H7.96191V3.53809C7.96191 2.09765 7.96175 1.37709 8.31543 0.864258C8.45309 0.664828 8.62674 0.492149 8.82617 0.354492C9.33903 0.000555366 10.0592 1.62347e-09 11.5 0Z"
      ],
      [
        "M58.7695 0C60.2107 0 60.9314 0.000460386 61.4443 0.354492C61.6437 0.49213 61.8165 0.664882 61.9541 0.864258C62.308 1.37711 62.3086 2.09739 62.3086 3.53809V7.96094H66.7314C68.1722 7.96094 68.8924 7.9615 69.4053 8.31543C69.6047 8.45308 69.7774 8.62578 69.915 8.8252C70.2691 9.3381 70.2695 10.0589 70.2695 11.5C70.2695 12.9408 70.269 13.661 69.915 14.1738C69.7774 14.3733 69.6047 14.5459 69.4053 14.6836C68.8924 15.0375 68.1722 15.0381 66.7314 15.0381H62.3086V19.4619C62.3086 20.9026 62.308 21.6229 61.9541 22.1357C61.8165 22.3351 61.6437 22.5079 61.4443 22.6455C60.9314 22.9995 60.2107 23 58.7695 23C57.3287 23 56.6086 22.9994 56.0957 22.6455C55.8963 22.5079 55.7226 22.3352 55.585 22.1357C55.2313 21.6229 55.2314 20.9024 55.2314 19.4619V15.0381H50.8076C49.3668 15.0381 48.6466 15.0375 48.1338 14.6836C47.9344 14.5459 47.7617 14.3733 47.624 14.1738C47.27 13.661 47.2695 12.9408 47.2695 11.5C47.2695 10.0589 47.27 9.3381 47.624 8.8252C47.7617 8.62578 47.9344 8.45308 48.1338 8.31543C48.6466 7.9615 49.3668 7.96094 50.8076 7.96094H55.2314V3.53809C55.2314 2.09765 55.2313 1.37709 55.585 0.864258C55.7226 0.664828 55.8963 0.492149 56.0957 0.354492C56.6086 0.000555366 57.3287 1.62347e-09 58.7695 0Z"
      ]
    ),
    (
      82, 8,
      [
        "M3.53125 0.164063C4.90133 0.164063 5.58673 0.163893 6.08301 0.485352C6.31917 0.638428 6.52075 0.840012 6.67383 1.07617C6.99555 1.57252 6.99512 2.25826 6.99512 3.62891C6.99512 4.99911 6.99536 5.68438 6.67383 6.18066C6.52075 6.41682 6.31917 6.61841 6.08301 6.77148C5.58672 7.09305 4.90147 7.09277 3.53125 7.09277C2.16062 7.09277 1.47486 7.09319 0.978516 6.77148C0.742356 6.61841 0.540772 6.41682 0.387695 6.18066C0.0662401 5.68439 0.0664063 4.999 0.0664063 3.62891C0.0664063 2.25838 0.0660571 1.57251 0.387695 1.07617C0.540772 0.840012 0.742356 0.638428 0.978516 0.485352C1.47485 0.163744 2.16076 0.164063 3.53125 0.164063Z",
        "M25.1836 0.164063C26.5542 0.164063 27.24 0.163638 27.7363 0.485352C27.9724 0.638384 28.1731 0.8401 28.3262 1.07617C28.6479 1.57252 28.6484 2.25825 28.6484 3.62891C28.6484 4.99931 28.6478 5.68436 28.3262 6.18066C28.1731 6.41678 27.9724 6.61842 27.7363 6.77148C27.24 7.09321 26.5542 7.09277 25.1836 7.09277H11.3262C9.95557 7.09277 9.26978 7.09317 8.77344 6.77148C8.53728 6.61841 8.33569 6.41682 8.18262 6.18066C7.86115 5.68438 7.86133 4.99902 7.86133 3.62891C7.86133 2.25835 7.86096 1.57251 8.18262 1.07617C8.33569 0.840012 8.53728 0.638428 8.77344 0.485352C9.26977 0.163768 9.95572 0.164063 11.3262 0.164063H25.1836Z",
      ],
      [
        "M78.2034 7.09325C76.8333 7.09325 76.1479 7.09342 75.6516 6.77197C75.4155 6.61889 75.2139 6.4173 75.0608 6.18114C74.7391 5.6848 74.7395 4.99905 74.7395 3.62841C74.7395 2.2582 74.7393 1.57294 75.0608 1.07665C75.2139 0.840493 75.4155 0.638909 75.6516 0.485832C76.1479 0.164271 76.8332 0.164543 78.2034 0.164543C79.574 0.164543 80.2598 0.164122 80.7561 0.485832C80.9923 0.638909 81.1939 0.840493 81.347 1.07665C81.6684 1.57293 81.6682 2.25831 81.6682 3.62841C81.6682 4.99894 81.6686 5.68481 81.347 6.18114C81.1939 6.4173 80.9923 6.61889 80.7561 6.77197C80.2598 7.09357 79.5739 7.09325 78.2034 7.09325Z",
        "M56.5511 7.09325C55.1804 7.09325 54.4947 7.09368 53.9983 6.77197C53.7622 6.61893 53.5615 6.41722 53.4085 6.18114C53.0868 5.6848 53.0862 4.99907 53.0862 3.62841C53.0862 2.258 53.0868 1.57296 53.4085 1.07665C53.5615 0.840539 53.7622 0.638898 53.9983 0.485832C54.4947 0.164105 55.1804 0.164543 56.5511 0.164543H70.4085C71.7791 0.164543 72.4649 0.164146 72.9612 0.485832C73.1974 0.638909 73.399 0.840493 73.552 1.07665C73.8735 1.57293 73.8733 2.25829 73.8733 3.62841C73.8733 4.99896 73.8737 5.68481 73.552 6.18114C73.399 6.4173 73.1974 6.61889 72.9612 6.77197C72.4649 7.09355 71.7789 7.09325 70.4085 7.09325H56.5511Z",
      ]
    ),
    (
      63, 9,
      [
        "M0 5.06511C0 4.94513 0 4.88513 0.00771184 4.79757C0.0483059 4.33665 0.341025 3.76395 0.690821 3.46107C0.757274 3.40353 0.783996 3.38422 0.837439 3.34559C2.40699 2.21129 6.03888 0 10.5 0C14.9611 0 18.593 2.21129 20.1626 3.34559C20.216 3.38422 20.2427 3.40353 20.3092 3.46107C20.659 3.76395 20.9517 4.33665 20.9923 4.79757C21 4.88513 21 4.94513 21 5.06511C21 6.01683 21 6.4927 20.9657 6.6754C20.7241 7.96423 19.8033 8.55941 18.5289 8.25054C18.3483 8.20676 17.8198 7.96876 16.7627 7.49275C14.975 6.68767 12.7805 6 10.5 6C8.21954 6 6.02504 6.68767 4.23727 7.49275C3.18025 7.96876 2.65174 8.20676 2.47108 8.25054C1.19668 8.55941 0.275917 7.96423 0.0342566 6.6754C0 6.4927 0 6.01683 0 5.06511Z"
      ],
      [
        "M42 5.06511C42 4.94513 42 4.88513 42.0077 4.79757C42.0483 4.33665 42.341 3.76395 42.6908 3.46107C42.7573 3.40353 42.784 3.38422 42.8374 3.34559C44.407 2.21129 48.0389 0 52.5 0C56.9611 0 60.593 2.21129 62.1626 3.34559C62.216 3.38422 62.2427 3.40353 62.3092 3.46107C62.659 3.76395 62.9517 4.33665 62.9923 4.79757C63 4.88513 63 4.94513 63 5.06511C63 6.01683 63 6.4927 62.9657 6.6754C62.7241 7.96423 61.8033 8.55941 60.5289 8.25054C60.3483 8.20676 59.8198 7.96876 58.7627 7.49275C56.975 6.68767 54.7805 6 52.5 6C50.2195 6 48.025 6.68767 46.2373 7.49275C45.1802 7.96876 44.6517 8.20676 44.4711 8.25054C43.1967 8.55941 42.2759 7.96423 42.0343 6.6754C42 6.4927 42 6.01683 42 5.06511Z"
      ]
    ),
  ]
}
