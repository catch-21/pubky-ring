import CoreText
import SwiftUI
import UIKit

extension Color {
  init(ringHex hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: opacity)
  }
}

/// Ring's dark theme (darkTheme in src/theme/index.ts). The consent sheet is always dark, like the app.
enum RingColour {
  static let background = Color(ringHex: 0x000000)
  static let foreground = Color(ringHex: 0xFFFFFF)
  static let secondaryForeground = Color(ringHex: 0xD4D4DB)
  static let mutedForeground = Color(ringHex: 0x89898F)
  static let card = Color(ringHex: 0x1D1D20)
  static let muted = Color(ringHex: 0x303034)
  static let popover = Color(ringHex: 0x05050A)
  static let border = Color(ringHex: 0x303034)
  static let input = Color(ringHex: 0x525252)
  static let secondary = Color(ringHex: 0x303034)
  static let blue = Color(ringHex: 0x0085FF)
  static let pubkyApp = Color(ringHex: 0xC8FF00)
  /// AuthIdentity's pill.
  static let identity = Color(ringHex: 0x1C1C1C)
}

/// Inter Tight, Ring's typeface, from assets/fonts (bundled into the extension's resources).
enum RingFont {
  private static let registered: Bool = {
    for name in ["InterTight-Regular", "InterTight-Medium", "InterTight-SemiBold", "InterTight-Bold"] {
      if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
    return true
  }()

  static func uiFont(size: CGFloat, weight: Int) -> UIFont {
    _ = registered
    let name: String
    let fallback: UIFont.Weight
    switch weight {
    case ..<500:
      name = "InterTight-Regular"
      fallback = .regular
    case 500:
      name = "InterTight-Medium"
      fallback = .medium
    case 600:
      name = "InterTight-SemiBold"
      fallback = .semibold
    default:
      name = "InterTight-Bold"
      fallback = .bold
    }
    return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: fallback)
  }
}

/// The text styles in src/theme/typography.ts, with React Native's fixed line heights.
struct RingTextStyle {
  let size: CGFloat
  let lineHeight: CGFloat
  let weight: Int
  var tracking: CGFloat = 0
  var uppercase = false
  let colour: Color

  static let lgSb = RingTextStyle(size: 18, lineHeight: 24, weight: 600, colour: RingColour.foreground)
  static let baseM = RingTextStyle(size: 16, lineHeight: 24, weight: 500, colour: RingColour.secondaryForeground)
  static let baseB = RingTextStyle(size: 16, lineHeight: 24, weight: 700, colour: RingColour.foreground)
  static let smM = RingTextStyle(size: 14, lineHeight: 20, weight: 500, colour: RingColour.mutedForeground)
  static let smB = RingTextStyle(size: 14, lineHeight: 20, weight: 700, colour: RingColour.foreground)
  static let xsM = RingTextStyle(
    size: 12, lineHeight: 16, weight: 500, tracking: 1, uppercase: true, colour: RingColour.mutedForeground)
  /// AuthSummary's sentence and its bold runs.
  static let summary = RingTextStyle(size: 17, lineHeight: 22, weight: 400, colour: RingColour.secondaryForeground)
  static let summaryBold = RingTextStyle(size: 17, lineHeight: 22, weight: 700, colour: RingColour.foreground)
  /// SwipeToConfirm's label.
  static let swipe = RingTextStyle(size: 15, lineHeight: 20, weight: 600, colour: RingColour.foreground)

  var font: Font { Font(RingFont.uiFont(size: size, weight: weight)) }

  /// React Native centres each line in `lineHeight`; SwiftUI gets the difference as spacing and padding.
  var extraLeading: CGFloat { max(0, lineHeight - RingFont.uiFont(size: size, weight: weight).lineHeight) }
}

struct RingLabel: View {
  let text: String
  var style: RingTextStyle = .baseM
  var colour: Color?

  init(_ text: String, _ style: RingTextStyle = .baseM, colour: Color? = nil) {
    self.text = text
    self.style = style
    self.colour = colour
  }

  var body: some View {
    Text(verbatim: style.uppercase ? text.uppercased() : text)
      .font(style.font)
      .tracking(style.tracking)
      .foregroundStyle(colour ?? style.colour)
      .lineSpacing(style.extraLeading)
      .padding(.vertical, style.extraLeading / 2)
  }
}

/// PermissionCard: the bordered card the Authorize sheet's details are grouped in.
struct RingCard<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      // React Native's padding sits inside the 1pt border.
      .padding(17)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 12).fill(RingColour.popover))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RingColour.border, lineWidth: 1))
      .shadow(color: RingColour.popover.opacity(0.5), radius: 20, x: 0, y: 20)
  }
}

/// Button size="large" in src/components/Button.tsx.
struct RingButton: View {
  enum Variant {
    case outline, secondary

    var foreground: Color { self == .secondary ? RingColour.secondaryForeground : RingColour.foreground }
  }

  let title: String
  var variant: Variant = .outline
  var icon: RingIcon?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let icon { RingIconView(icon: icon, size: 16, colour: variant.foreground) }
        RingLabel(title, .smB, colour: variant.foreground).lineLimit(1)
      }
    }
    .buttonStyle(RingButtonStyle(variant: variant))
  }
}

struct RingButtonStyle: ButtonStyle {
  let variant: RingButton.Variant
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60)
      .background {
        ZStack {
          Capsule().fill(variant == .outline ? Color.white.opacity(0.045) : RingColour.secondary)
          if configuration.isPressed {
            Capsule().fill(variant == .outline ? Color.white.opacity(0.075) : Color(ringHex: 0x454549))
          }
          if variant == .outline { Capsule().strokeBorder(RingColour.border, lineWidth: 1) }
        }
      }
      .contentShape(Capsule())
      .shadow(color: RingColour.popover.opacity(0.25), radius: 2, x: 0, y: 1)
      .opacity(isEnabled ? 1 : 0.4)
  }
}

struct RingPathShape: Shape {
  let commands: [RingPathCommand]
  var viewBox = CGSize(width: 24, height: 24)

  func path(in rect: CGRect) -> Path {
    let scaleX = rect.width / viewBox.width
    let scaleY = rect.height / viewBox.height
    func point(_ p: RingPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * scaleX, y: rect.minY + p.y * scaleY) }
    var path = Path()
    for command in commands {
      switch command {
      case .move(let p): path.move(to: point(p))
      case .line(let p): path.addLine(to: point(p))
      case .quad(let c, let p): path.addQuadCurve(to: point(p), control: point(c))
      case .cubic(let c1, let c2, let p): path.addCurve(to: point(p), control1: point(c1), control2: point(c2))
      case .close: path.closeSubpath()
      }
    }
    return path
  }
}

/// A Lucide icon as src/icons/createIcon.tsx draws it: stroke 2 on a 24pt grid, scaled with the size.
struct RingIconView: View {
  let icon: RingIcon
  var size: CGFloat = 24
  var colour: Color = RingColour.foreground
  var strokeWidth: CGFloat = 2

  var body: some View {
    let paths = icon.paths
    ZStack {
      ForEach(paths.stroke.indices, id: \.self) { index in
        RingPathShape(commands: RingSVGPath.parse(paths.stroke[index]))
          .stroke(
            colour, style: StrokeStyle(lineWidth: strokeWidth * size / 24, lineCap: .round, lineJoin: .round))
      }
      ForEach(paths.fill.indices, id: \.self) { index in
        RingPathShape(commands: RingSVGPath.parse(paths.fill[index])).fill(colour)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}
