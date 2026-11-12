import SwiftUI
import UIKit

/// State of the extension's consent sheet. Mirrors src/screens/PasskeyConsent.tsx.
final class PasskeyConsentModel: ObservableObject {
  enum Phase: Equatable {
    case loading
    /// The provider's own credential list (prepareCredentialList) with more than one pubky.
    case choosing
    case consent
    case authorising
    /// The extension was opened from Settings to finish setting it up.
    case info
  }

  @Published var phase: Phase = .loading {
    didSet {
      if phase == .consent && oldValue != .consent { consentGeneration += 1 }
    }
  }
  /// Bumped whenever consent is shown again, which restarts the timer.
  @Published private(set) var consentGeneration = 0
  @Published var showDetails = false
  @Published var encryptionApproved = true
  @Published var choices: [ConsentIdentity] = []
  @Published var rpId = ""
  @Published var relay: String?
  @Published var identity: ConsentIdentity?
  /// As requested, before the user's encryption choice.
  @Published var capabilities: [AuthCapability] = []

  var approvedCapabilities: [AuthCapability] {
    AuthCapability.approved(capabilities, encryptionApproved: encryptionApproved)
  }
}

/// The Authorize sheet (ConfirmAuth) in SwiftUI: the same chrome, basic and details views and swipe
/// to authorise, in Ring's dark theme. There is no success state: the assertion goes back at once.
struct PasskeyConsentView: View {
  static let consentTimeout: TimeInterval = 60

  @ObservedObject var model: PasskeyConsentModel
  let onApprove: () -> Void
  let onDeny: () -> Void
  let onChoose: (String) -> Void

  private enum RequestView: Hashable { case basic, details }

  private var t: (String, [String: String]) -> String { RingStrings.t }

  var body: some View {
    VStack(spacing: 0) {
      Capsule()
        .fill(RingColour.muted)
        .frame(width: 60, height: 6)
        .padding(.top, 16)
        .padding(.bottom, 24)
      header
      content
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background {
      LinearGradient(colors: [RingColour.card, RingColour.background], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
    .environment(\.colorScheme, .dark)
    .preferredColorScheme(.dark)
    .accessibilityAction(.escape) { escape() }
  }

  // MARK: Chrome (SheetLayout)

  private var title: String {
    switch model.phase {
    case .info: return t("passkey.setup.title", [:])
    case .choosing: return t("pubky.selectPubky", [:])
    case .loading, .consent, .authorising: return t("auth.authorize", [:])
    }
  }

  private var header: some View {
    HStack(spacing: 0) {
      ZStack {
        if model.showDetails && model.phase == .consent {
          Button {
            model.showDetails = false
          } label: {
            RingIconView(icon: .arrowLeft, size: 24)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(t("common.back", [:]))
        }
      }
      .frame(width: 24, height: 24)
      RingLabel(title, .lgSb)
        .lineLimit(1)
        .truncationMode(.tail)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .accessibilityAddTraits(.isHeader)
      ZStack {
        if model.phase == .consent {
          RingTimer(duration: Self.consentTimeout).id(model.consentGeneration)
        }
      }
      .frame(width: 24, height: 24)
    }
    .frame(height: 24)
    .padding(.horizontal, 16)
    .padding(.bottom, 24)
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .loading:
      ProgressView().tint(RingColour.foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
    case .info:
      messageLayout(t("passkey.setup.message", [:]), button: t("common.done", [:]))
    case .choosing:
      picker
    case .consent, .authorising:
      if let identity = model.identity { request(identity) }
    }
  }

  private func messageLayout(_ text: String, button: String) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        RingLabel(text, .baseM).frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
      RingButton(title: button, action: onDeny).padding(.bottom, 12)
    }
  }

  /// Only reached from the provider's own list with several pubkys; the OS picks the pubky otherwise.
  private var picker: some View {
    VStack(alignment: .leading, spacing: 24) {
      RingLabel(t("pubky.selectPubkyMessage", [:]), .baseM)
      ScrollView {
        VStack(spacing: 12) {
          ForEach(model.choices) { choice in
            Button {
              onChoose(choice.pubky)
            } label: {
              RingIdentityPill(identity: choice, fullWidth: true)
            }
            .buttonStyle(.plain)
          }
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      RingButton(title: t("common.cancel", [:]), variant: .secondary, action: onDeny).padding(.bottom, 12)
    }
  }

  // MARK: Request (AuthRequestContent)

  private func request(_ identity: ConsentIdentity) -> some View {
    let view: RequestView =
      model.showDetails ? .details : .basic
    let authorising = model.phase == .authorising
    return VStack(spacing: 0) {
      // The basic view never scrolls, so a downward drag anywhere on it closes the sheet. The
      // details fill the sheet when they fit and scroll when they do not; the controller's drag
      // then closes the sheet only from the top of the scroll.
      Group {
        if view == .basic {
          requestBody(view, identity: identity).frame(maxHeight: .infinity, alignment: .top)
        } else {
          ViewThatFits(in: .vertical) {
            requestBody(view, identity: identity).frame(maxHeight: .infinity, alignment: .top)
            ScrollView { requestBody(view, identity: identity) }.scrollBounceBehavior(.basedOnSize)
          }
        }
      }
      .id(view)
      VStack(spacing: 24) {
        if view == .details {
          RingIdentityPill(identity: identity, fullWidth: true)
        } else if view == .basic {
          RingButton(title: t("auth.showDetails", [:]), icon: .list) { model.showDetails = true }
            .disabled(authorising)
        }
        RingSwipeToConfirm(
          text: t(authorising ? "auth.authorizing" : "auth.swipeToAuthorize", [:]), loading: authorising,
          onConfirm: onApprove)
      }
      .padding(.bottom, 12)
    }
  }

  @ViewBuilder private func requestBody(_ view: RequestView, identity: ConsentIdentity) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      switch view {
      case .basic:
        RingAuthSummary(capabilities: model.approvedCapabilities)
        ZStack {
          if let shield = UIImage(named: "shield") {
            Image(uiImage: shield).resizable().scaledToFit().accessibilityHidden(true)
          }
          RingIdentityPill(identity: identity)
        }
        .frame(maxWidth: 327)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .details:
        details
      }
    }
    .padding(.bottom, 24)
  }

  private var details: some View {
    let capabilities = model.capabilities
    let identityOnly = !capabilities.contains { !$0.permission.isEmpty }
    let hasEncryption = AuthCapability.hasEncryption(capabilities)
    let warning =
      identityOnly
      ? "auth.identityVerificationWarning" : hasEncryption ? "auth.encryptionTrustWarning" : "auth.trustWarning"
    return VStack(alignment: .leading, spacing: 0) {
      VStack(spacing: 24) {
        RingCard {
          sectionTitle(t("passkey.requestingSite", [:]))
          HStack(spacing: 8) {
            RingIconView(icon: .globe, size: 16)
            RingLabel(model.rpId, .smM, colour: RingColour.foreground)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            RingIconView(icon: .shield, size: 16, colour: RingColour.pubkyApp)
          }
          RingLabel(t("passkey.verifiedByBrowser", [:]), .smM).padding(.top, 8)
        }
        RingCard {
          if identityOnly {
            sectionTitle(t("auth.identityVerification", [:]))
            HStack(spacing: 8) {
              RingIconView(icon: .userRoundCheck, size: 16)
              RingLabel(t("auth.provePubkyControl", [:]), .smM, colour: RingColour.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          } else {
            HStack {
              RingLabel(t("auth.folder", [:]), .xsM)
              Spacer(minLength: 8)
              RingLabel(t("auth.permissions", [:]), .xsM)
            }
            .padding(.bottom, 8)
            VStack(spacing: 8) {
              ForEach(capabilities.indices, id: \.self) { index in
                permissionRow(capabilities[index])
              }
            }
          }
        }
        if hasEncryption {
          RingCard {
            sectionTitle(t("auth.encryptedData", [:]))
            HStack(spacing: 8) {
              RingIconView(icon: .lock, size: 16)
              RingLabel(t("auth.allowEncryptedData", [:]), .smM, colour: RingColour.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
              RingSwitch(isOn: $model.encryptionApproved, label: t("auth.allowEncryptedData", [:]))
                .disabled(model.phase == .authorising)
            }
          }
        }
        if let relay = model.relay, !relay.isEmpty {
          RingCard {
            sectionTitle(t("auth.relay", [:]))
            HStack(spacing: 8) {
              RingIconView(icon: .globe, size: 16)
              RingLabel(relay, .smM, colour: RingColour.foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      Spacer(minLength: 24)
      RingLabel(t(warning, [:]), .smM)
    }
  }

  private func sectionTitle(_ text: String) -> some View {
    RingLabel(text, .xsM).padding(.bottom, 8)
  }

  private func permissionRow(_ capability: AuthCapability) -> some View {
    let read = capability.permission.contains("r")
    let write = capability.permission.contains("w")
    let encrypt = capability.permission.contains(AuthCapability.encryptionAction) && model.encryptionApproved
    let label = [
      read ? t("common.read", [:]) : nil, write ? t("common.write", [:]) : nil,
      encrypt ? t("auth.encryptedData", [:]) : nil,
    ]
    .compactMap { $0 }
    .joined(separator: ", ")
    let spokenLabel = "\(capability.path): \(label.isEmpty ? t("activeSession.noPermissions", [:]) : label)"
    return HStack(spacing: 8) {
      RingIconView(icon: .folder, size: 16)
      RingLabel(capability.path, .smM, colour: RingColour.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 12) {
        RingIconView(icon: .eye, size: 16, colour: read ? RingColour.foreground : RingColour.border)
        RingIconView(icon: .pencil, size: 16, colour: write ? RingColour.foreground : RingColour.border)
        RingIconView(icon: .lock, size: 16, colour: encrypt ? RingColour.foreground : RingColour.border)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spokenLabel)
  }

  private func escape() {
    switch model.phase {
    case .consent where model.showDetails:
      model.showDetails = false
    case .authorising:
      break
    default:
      onDeny()
    }
  }
}
