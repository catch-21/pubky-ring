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

  override func viewDidLoad() {
    super.viewDidLoad()
    let host = UIHostingController(
      rootView: PasskeyConsentView(
        model: model,
        onApprove: { [weak self] in self?.approve() },
        onDeny: { [weak self] in self?.deny() },
        onChoose: { [weak self] in self?.choose(pubky: $0) }))
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
    else { return fail("This request is not a Pubky sign-in.") }
    var prfInput: Data?
    if #available(iOS 18.0, *) {
      prfInput = request.assertionExtensionInput?.prf?.inputValues?.saltInput1
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
      return fail("Open Pubky Ring and add a pubky first.")
    }
    if snapshot.identities.count == 1 {
      return choose(pubky: snapshot.identities[0].pubky)
    }
    model.choices = snapshot.identities.map {
      (pubky: $0.pubky, name: $0.name.isEmpty ? PasskeyShared.shortPubky($0.pubky) : $0.name)
    }
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
        return fail("This pubky is no longer in Pubky Ring.")
      }
      let envelopeBytes: Data
      if let fromAllowList = allowedCredentials.first(where: PasskeyEnvelope.hasMagic) {
        envelopeBytes = fromAllowList
      } else if let prfInput {
        do {
          envelopeBytes = try await PasskeyMailbox.fetchEnvelope(prfInput: prfInput, rpId: rpId)
        } catch {
          return fail("Pubky Ring could not find the sign-in request. Go back to the website and try again.")
        }
      } else {
        return fail("This version of iOS did not pass the sign-in request to Pubky Ring. iOS 18 or later is needed.")
      }
      let now = UInt32(Date().timeIntervalSince1970)
      switch PasskeyPolicy.validate(envelopeBytes: envelopeBytes, rpId: rpId, now: now, hasSeenNonce: PasskeyNonceCache.has) {
      case .failure(let reason):
        fail(Self.message(for: reason))
      case .success(let validated):
        pending = PendingRequest(
          rpId: rpId, clientDataHash: clientDataHash, identity: identity, snapshot: snapshot, validated: validated)
        model.rpId = rpId
        model.pubky = identity.pubky
        model.identityName = identity.name.isEmpty ? PasskeyShared.shortPubky(identity.pubky) : identity.name
        model.capabilities = PasskeyConsentView.parseCapabilities(validated.link.capabilities)
        // Auto Auth is a development setting; it skips consent exactly as QR scanning does.
        if snapshot.autoAuth {
          approve()
        } else {
          model.phase = .consent
        }
      }
    }
  }

  private func approve() {
    guard let pending, model.phase != .authorising else { return }
    model.phase = .authorising
    Task { @MainActor in
      do {
        let envelope = pending.validated.envelope
        let userVerified = try await PasskeyApprover.approve(
          url: envelope.url, identity: pending.identity, capabilities: pending.validated.link.capabilities ?? "",
          requireDeviceAuth: pending.snapshot.requireDeviceAuth)
        PasskeyNonceCache.remember(envelope.nonce, until: envelope.exp)
        let credentialId = PasskeyShared.credentialId(rpId: pending.rpId, pubky: pending.identity.pubky)
        let key = try CeremonyKeys.loadOrCreate(credentialId: credentialId)
        let authenticatorData = WebAuthnEncoding.authenticatorData(rpId: pending.rpId, userVerified: userVerified)
        let signature = try key.sign(authenticatorData + pending.clientDataHash)
        let credential = ASPasskeyAssertionCredential(
          userHandle: Data(pending.identity.pubky.utf8), relyingParty: pending.rpId, signature: signature,
          clientDataHash: pending.clientDataHash, authenticatorData: authenticatorData, credentialID: credentialId)
        extensionContext.completeAssertionRequest(using: credential)
      } catch PasskeyApprover.Failure.deviceAuthFailed {
        model.phase = .consent
      } catch {
        fail(error.localizedDescription)
      }
    }
  }

  private func deny() {
    if isConfiguring {
      extensionContext.completeExtensionConfigurationRequest()
      return
    }
    extensionContext.cancelRequest(withError: ASExtensionError(hasFailed ? .failed : .userCanceled))
  }

  private func fail(_ message: String) {
    hasFailed = true
    model.phase = .failed(message)
  }

  private static func message(for reason: PasskeyPolicy.Rejection) -> String {
    switch reason {
    case .expired, .lifetime: return "This sign-in request has expired. Go back to the website and try again."
    case .replayed: return "This sign-in request was already used."
    case .clientIdMismatch, .originMismatch: return "The app named in the request does not match the website."
    case .insecureRelay: return "The request uses an insecure relay."
    case .unsupportedLink, .malformed: return "Pubky Ring does not support this sign-in request."
    }
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
        await MainActor.run { extensionContext.completeRegistrationRequest(using: credential) }
      }
    } catch {
      extensionContext.cancelRequest(withError: ASExtensionError(.failed))
    }
  }

  // MARK: Configuration

  override func prepareInterfaceForExtensionConfiguration() {
    isConfiguring = true
    model.phase = .info(
      "Pubky Ring can now sign you in to Pubky websites from the passkey sheet. Open Pubky Ring once so it can list your pubkys here.")
  }
}
