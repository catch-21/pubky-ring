import AuthenticationServices
import SwiftUI

/// Pubky Ring's passkey provider (PLAN.md section 5). The extension's deployment target is iOS 17,
/// the first release that lets third-party providers answer passkey requests; the PRF mailbox
/// needs iOS 18 and is gated with #available. The app itself still supports iOS 15.1.
final class CredentialProviderViewController: ASCredentialProviderViewController {
  private struct PendingRequest {
    let rpId: String
    let clientDataHash: Data
    let identity: PasskeySnapshot.Identity
    let snapshot: PasskeySnapshot
    let validated: PasskeyPolicy.Validated
  }

  private struct ListRequest {
    let rpId: String
    let clientDataHash: Data
    let allowedCredentials: [Data]
    let prfInput: Data?
  }

  private let model = PasskeyConsentModel()
  private var pending: PendingRequest?
  private var listRequest: ListRequest?
  private var isConfiguring = false
  private var hasFailed = false
  private var isFinished = false

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = .black
    let host = UIHostingController(
      rootView: PasskeyConsentView(
        model: model,
        onApprove: { [weak self] in self?.approve() },
        onDeny: { [weak self] in self?.deny() },
        onChoose: { [weak self] in self?.choose(pubky: $0) }))
    host.overrideUserInterfaceStyle = .dark
    host.view.backgroundColor = .clear
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
  }

  // MARK: Assertion

  override func provideCredentialWithoutUserInteraction(for credentialRequest: ASCredentialRequest) {
    // Consent is mandatory, so always ask the system for the interactive path.
    extensionContext.cancelRequest(withError: ASExtensionError(.userInteractionRequired))
  }

  override func prepareInterfaceToProvideCredential(for credentialRequest: ASCredentialRequest) {
    guard let request = credentialRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
      let pubky = String(data: identity.userHandle, encoding: .utf8)
    else { return fail(RingStrings.t("passkey.errors.not_pubky_request")) }
    var prfInput: Data?
    if #available(iOS 18.0, *) {
      if case .assertion(let input) = request.extensionInput {
        prfInput = input.prf?.inputValues?.saltInput1
      }
    }
    start(
      rpId: identity.relyingPartyIdentifier, pubky: pubky, clientDataHash: request.clientDataHash,
      allowedCredentials: [], prfInput: prfInput)
  }

  override func prepareCredentialList(
    for serviceIdentifiers: [ASCredentialServiceIdentifier], requestParameters: ASPasskeyCredentialRequestParameters
  ) {
    var prfInput: Data?
    if #available(iOS 18.0, *) {
      prfInput = requestParameters.extensionInput?.prf?.inputValues?.saltInput1
    }
    listRequest = ListRequest(
      rpId: requestParameters.relyingPartyIdentifier, clientDataHash: requestParameters.clientDataHash,
      allowedCredentials: requestParameters.allowedCredentials, prfInput: prfInput)
    guard let snapshot = PasskeySnapshot.load(), !snapshot.identities.isEmpty else {
      return fail(RingStrings.t("passkey.errors.no_pubkys"))
    }
    if snapshot.identities.count == 1 {
      return choose(pubky: snapshot.identities[0].pubky)
    }
    // On the identity path the OS has already picked the pubky; this list path has to ask.
    model.choices = snapshot.identities.map(ConsentIdentity.init)
    model.phase = .choosing
  }

  private func choose(pubky: String) {
    guard let listRequest else { return }
    start(
      rpId: listRequest.rpId, pubky: pubky, clientDataHash: listRequest.clientDataHash,
      allowedCredentials: listRequest.allowedCredentials, prfInput: listRequest.prfInput)
  }

  private func start(rpId: String, pubky: String, clientDataHash: Data, allowedCredentials: [Data], prfInput: Data?) {
    model.phase = .loading
    Task { @MainActor in
      guard let snapshot = PasskeySnapshot.load(), let identity = snapshot.identity(for: pubky) else {
        return fail(RingStrings.t("passkey.errors.unknown_pubky"))
      }
      let envelopeBytes: Data
      if let fromAllowList = allowedCredentials.first(where: PasskeyEnvelope.hasMagic) {
        envelopeBytes = fromAllowList
      } else if let prfInput {
        do {
          envelopeBytes = try await PasskeyMailbox.fetchEnvelope(prfInput: prfInput, rpId: rpId)
        } catch {
          return fail(RingStrings.t("passkey.errors.request_not_found"))
        }
      } else {
        return fail(RingStrings.t("passkey.errors.ios_too_old"))
      }
      let now = UInt32(Date().timeIntervalSince1970)
      switch PasskeyPolicy.validate(envelopeBytes: envelopeBytes, rpId: rpId, now: now, hasSeenNonce: PasskeyNonceCache.has) {
      case .failure(let reason):
        fail(RingStrings.t("passkey.errors.\(reason.rawValue)"))
      case .success(let validated):
        pending = PendingRequest(
          rpId: rpId, clientDataHash: clientDataHash, identity: identity, snapshot: snapshot, validated: validated)
        model.rpId = rpId
        model.relay = validated.link.relay
        model.identity = ConsentIdentity(identity)
        model.capabilities = AuthCapability.parse(validated.link.capabilities)
        model.encryptionApproved = true
        model.showDetails = snapshot.alwaysShowAuthDetails ?? false
        // Auto Auth is a development setting; it skips consent exactly as QR scanning does.
        if snapshot.autoAuth {
          approve()
        } else {
          showConsent()
        }
      }
    }
  }

  private func showConsent() {
    model.phase = .consent
    let generation = model.consentGeneration
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(PasskeyConsentView.consentTimeout * 1_000_000_000))
      guard let self, self.model.phase == .consent, self.model.consentGeneration == generation else { return }
      self.deny()
    }
  }

  private func approve() {
    guard let pending, model.phase == .consent || model.phase == .loading, !isFinished else { return }
    model.phase = .authorising
    // As on Android: the approved scopes are sent only when the user had an encryption choice.
    let capabilities =
      AuthCapability.hasEncryption(model.capabilities)
      ? AuthCapability.serialise(model.approvedCapabilities) : pending.validated.link.capabilities ?? ""
    Task { @MainActor in
      do {
        let envelope = pending.validated.envelope
        let userVerified = try await PasskeyApprover.approve(
          url: envelope.url, identity: pending.identity, capabilities: capabilities,
          requireDeviceAuth: pending.snapshot.requireDeviceAuth)
        PasskeyNonceCache.remember(envelope.nonce, until: envelope.exp)
        let credentialId = PasskeyShared.credentialId(rpId: pending.rpId, pubky: pending.identity.pubky)
        let key = try CeremonyKeys.loadOrCreate(credentialId: credentialId)
        let authenticatorData = WebAuthnEncoding.authenticatorData(rpId: pending.rpId, userVerified: userVerified)
        let signature = try key.sign(authenticatorData + pending.clientDataHash)
        let credential = ASPasskeyAssertionCredential(
          userHandle: Data(pending.identity.pubky.utf8), relyingParty: pending.rpId, signature: signature,
          clientDataHash: pending.clientDataHash, authenticatorData: authenticatorData, credentialID: credentialId)
        // The website signs in as soon as it has the grant, so hand the assertion back at once.
        isFinished = true
        extensionContext.completeAssertionRequest(using: credential) { _ in }
      } catch PasskeyApprover.Failure.deviceAuthFailed {
        showConsent()
      } catch PasskeyApprover.Failure.secretUnavailable {
        fail(RingStrings.t("passkey.errors.secret_unavailable"))
      } catch PasskeyApprover.Failure.authFailed(let message) {
        fail(message.isEmpty ? RingStrings.t("passkey.errors.generic") : message)
      } catch {
        fail(RingStrings.t("passkey.errors.generic"))
      }
    }
  }

  private func deny() {
    if isConfiguring {
      extensionContext.completeExtensionConfigurationRequest()
      return
    }
    guard !isFinished else { return }
    isFinished = true
    extensionContext.cancelRequest(withError: ASExtensionError(hasFailed ? .failed : .userCanceled))
  }

  private func fail(_ message: String) {
    hasFailed = true
    model.phase = .failed(message)
  }

  // MARK: Registration (PLAN.md section 4.6)

  override func prepareInterface(forPasskeyRegistration registrationRequest: ASCredentialRequest) {
    guard let request = registrationRequest as? ASPasskeyCredentialRequest,
      let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
      let pubky = String(data: identity.userHandle, encoding: .utf8),
      request.supportedAlgorithms.contains(.ES256),
      PasskeySnapshot.load()?.identity(for: pubky) != nil
    else {
      extensionContext.cancelRequest(withError: ASExtensionError(.failed))
      return
    }
    let rpId = identity.relyingPartyIdentifier
    let credentialId = PasskeyShared.credentialId(rpId: rpId, pubky: pubky)
    do {
      let key = try CeremonyKeys.loadOrCreate(credentialId: credentialId)
      let authenticatorData = WebAuthnEncoding.authenticatorData(
        rpId: rpId, userVerified: false,
        attestedCredentialData: WebAuthnEncoding.attestedCredentialData(
          credentialId: credentialId, publicKey: key.publicKey))
      PasskeyShared.addRegisteredRpId(rpId, pubky: pubky)
      let stored = ASPasskeyCredentialIdentity(
        relyingPartyIdentifier: rpId, userName: identity.userName, credentialID: credentialId,
        userHandle: identity.userHandle, recordIdentifier: pubky)
      Task {
        try? await ASCredentialIdentityStore.shared.saveCredentialIdentities([stored])
        let credential = ASPasskeyRegistrationCredential(
          relyingParty: rpId, clientDataHash: request.clientDataHash, credentialID: credentialId,
          attestationObject: WebAuthnEncoding.noneAttestationObject(authData: authenticatorData))
        extensionContext.completeRegistrationRequest(using: credential) { _ in }
      }
    } catch {
      extensionContext.cancelRequest(withError: ASExtensionError(.failed))
    }
  }

  // MARK: Configuration

  override func prepareInterfaceForExtensionConfiguration() {
    isConfiguring = true
    model.phase = .info
  }
}
