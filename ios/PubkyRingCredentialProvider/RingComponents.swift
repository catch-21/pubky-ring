import SwiftUI
import UIKit

/// The pubky shown on the consent sheet, with the fields Ring's AuthIdentity and ProfileAvatar read.
struct ConsentIdentity: Identifiable, Equatable {
  /// z32 pubky, the passkey user handle.
  let pubky: String
  let storeKey: String
  /// The pubky's own name (ProfileAvatar's initial comes from it).
  let name: String
  /// getPubkyName: the truncated name, or "pubky #N".
  let displayName: String?
  /// Imported from another app (Bitkit), which gives the avatar Bitkit's colour.
  let external: Bool

  var id: String { pubky }

  init(_ identity: PasskeySnapshot.Identity) {
    pubky = identity.pubky
    storeKey = identity.storeKey
    name = identity.name
    displayName = identity.displayName ?? (identity.name.isEmpty ? nil : RingFormat.truncate(identity.name, 8))
    external = identity.sourceApp != nil
  }
}

/// ProfileAvatar without an image (Ring never sets one): a Facehash with Ring's palette and initial.
struct RingAvatar: View {
  private static let palette: [UInt32] = [0x00FF5D, 0x00F0FF, 0x004BFF, 0xFC00FF, 0xFF0000, 0xFF9900]
  private static let externalPalette: [UInt32] = [0xFF4400]

  let identity: ConsentIdentity
  var size: CGFloat = 20

  var body: some View {
    let seed = RingFormat.avatarSeed(identity.storeKey)
    let palette = identity.external ? Self.externalPalette : Self.palette
    let face = RingFacehash(seed: seed, colourCount: palette.count)
    let transform = face.transform
    let eyes = (face.geometry.leftEye + face.geometry.rightEye).map { transform.apply(RingSVGPath.parse($0)) }
    let centre = face.gradientCentre
    ZStack {
      Color(ringHex: palette[face.colourIndex])
      RadialGradient(
        colors: [Color.white.opacity(0.15), Color.white.opacity(0)],
        center: UnitPoint(x: centre.x / 100, y: centre.y / 100), startRadius: 0, endRadius: size * 0.7)
      ForEach(eyes.indices, id: \.self) { index in
        RingPathShape(commands: eyes[index], viewBox: CGSize(width: 100, height: 100)).fill(Color.black)
      }
      Text(verbatim: RingFormat.avatarInitial(name: identity.name, seed: seed))
        .font(.system(size: size * 0.26, weight: .medium))
        .foregroundStyle(Color(ringHex: 0x050505))
        .fixedSize()
        .position(x: size / 2, y: size * 0.7)
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }
}

/// src/components/AuthIdentity.tsx.
struct RingIdentityPill: View {
  let identity: ConsentIdentity
  var fullWidth = false

  var body: some View {
    let publicKey = RingFormat.truncatePubky(identity.storeKey)
    HStack(spacing: 8) {
      RingAvatar(identity: identity)
      RingLabel(identity.displayName ?? publicKey, .baseB).lineLimit(1)
      if fullWidth && identity.displayName != nil {
        Spacer(minLength: 0)
        HStack(spacing: 8) {
          RingIconView(icon: .keyRound, size: 16, colour: RingColour.mutedForeground)
          RingLabel(publicKey, .baseM, colour: RingColour.mutedForeground).lineLimit(1)
        }
        .fixedSize()
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
    .background(Capsule().fill(RingColour.identity))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([identity.displayName, publicKey].compactMap { $0 }.joined(separator: ", "))
  }
}

/// AuthSummary: one sentence whose scope and "encrypted" runs are bold.
struct RingAuthSummary: View {
  let capabilities: [AuthCapability]

  var body: some View {
    let regular = RingTextStyle.summary
    let bold = RingTextStyle.summaryBold
    let runs = AuthSummaryText.runs(capabilities: capabilities, authorised: false, t: RingStrings.t)
    runs.reduce(Text(verbatim: "")) { text, run in
      text
        + Text(verbatim: run.text)
        .font(run.bold ? bold.font : regular.font)
        .foregroundStyle(run.bold ? bold.colour : regular.colour)
    }
    .lineSpacing(regular.extraLeading)
    .padding(.vertical, regular.extraLeading / 2)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The encryption toggle in the Authorize sheet's details (36×20, blue when on).
struct RingSwitch: View {
  @Binding var isOn: Bool
  let label: String

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      Capsule()
        .fill(isOn ? RingColour.blue : RingColour.input)
        .frame(width: 36, height: 20)
        .overlay(alignment: .leading) {
          Circle().fill(RingColour.background).frame(width: 16, height: 16).offset(x: isOn ? 18 : 2)
        }
        .padding(12)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(-12)
    .accessibilityRepresentation { Toggle(label, isOn: $isOn) }
  }
}

/// CircularProgressBar with `drain`: a 24pt ring that empties over `duration`.
struct RingTimer: View {
  let duration: TimeInterval
  @State private var progress: CGFloat = 1

  var body: some View {
    Circle()
      .trim(from: 1 - progress, to: 1)
      .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      .rotationEffect(.degrees(-90))
      .padding(0.75)
      .frame(width: 24, height: 24)
      .onAppear {
        withAnimation(.linear(duration: duration)) { progress = 0 }
      }
      .accessibilityHidden(true)
  }
}

/// Reanimated's defaults, which SwipeToConfirm uses.
enum RingMotion {
  /// withTiming: 300 ms, Easing.inOut(Easing.quad).
  static let timing = Animation.timingCurve(0.455, 0.03, 0.515, 0.955, duration: 0.3)
  /// withSpring: the "gentle" preset (mass 4, stiffness 900, damping 120).
  static let spring = Animation.interpolatingSpring(mass: 4, stiffness: 900, damping: 120, initialVelocity: 0)
}

/// src/components/SwipeToConfirm.tsx: drag the blue handle at least 80% of the way to confirm.
struct RingSwipeToConfirm: View {
  private static let handleSize: CGFloat = 60
  private static let inset: CGFloat = 8

  let text: String
  let loading: Bool
  var disabled = false
  let onConfirm: () -> Void

  @State private var width: CGFloat = 0
  @State private var panX: CGFloat = 0
  @State private var pending = false
  @State private var committed = false
  @State private var dragFailed = false

  private var maxPanX: CGFloat { max(0, width - Self.handleSize - Self.inset * 2) }
  private var busy: Bool { loading || pending }
  private var labelOpacity: Double { maxPanX > 0 ? Double(min(max(1 - panX / maxPanX, 0), 1)) : 1 }

  var body: some View {
    ZStack(alignment: .leading) {
      LinearGradient(
        colors: [Color(ringHex: 0x2A2A2A), Color(ringHex: 0x1C1C1C)], startPoint: .top, endPoint: .bottom)
      Capsule()
        .fill(RingColour.blue.opacity(Double(0x24) / 255))
        .frame(width: panX + Self.handleSize, height: Self.handleSize)
        .padding(.leading, Self.inset)
      RingLabel(text, .swipe)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Self.handleSize + Self.inset)
        .frame(maxWidth: .infinity)
        .opacity(labelOpacity)
      handle
        .offset(x: panX)
        .padding(.leading, Self.inset)
        .gesture(drag)
    }
    .frame(height: Self.handleSize + Self.inset * 2)
    .frame(maxWidth: .infinity)
    .clipShape(Capsule())
    .background {
      GeometryReader { geometry in
        Color.clear
          .onAppear { width = geometry.size.width }
          .onChange(of: geometry.size.width) { _, newWidth in width = newWidth }
      }
    }
    .opacity(disabled ? 0.4 : 1)
    .onChange(of: busy) { _, isBusy in
      withAnimation(RingMotion.timing) { panX = isBusy ? maxPanX : 0 }
    }
    .onChange(of: loading) { _, isLoading in
      if !isLoading { reset() }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { confirm() }
  }

  private var handle: some View {
    ZStack {
      Circle().fill(RingColour.blue)
      if busy {
        ProgressView().tint(RingColour.background)
      } else {
        RingPathShape(commands: RingSVGPath.parse(RingSwipeArrow.path))
          .fill(Color(ringHex: 0x101010))
          .frame(width: 24, height: 24)
          .rotationEffect(.degrees(-90))
      }
    }
    .frame(width: Self.handleSize, height: Self.handleSize)
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .global)
      .onChanged { value in
        guard !busy, !disabled, !committed, maxPanX > 0 else { return }
        if panX == 0 && !dragFailed && abs(value.translation.height) > 16
          && abs(value.translation.height) > abs(value.translation.width)
        {
          dragFailed = true
        }
        guard !dragFailed else { return }
        panX = min(max(value.translation.width, 0), maxPanX)
      }
      .onEnded { _ in
        defer { dragFailed = false }
        guard !committed else { return }
        if !busy, !disabled, maxPanX > 0, panX >= maxPanX * 0.8 {
          committed = true
          withAnimation(RingMotion.spring) { panX = maxPanX }
          confirm()
        } else {
          withAnimation(RingMotion.spring) { panX = 0 }
        }
      }
  }

  private func confirm() {
    guard !pending, !loading, !disabled else { return }
    pending = true
    onConfirm()
  }

  private func reset() {
    pending = false
    committed = false
    withAnimation(RingMotion.spring) { panX = 0 }
  }
}
