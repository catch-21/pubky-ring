import SwiftUI

/// Native consent sheet for the extension. Mirrors src/screens/PasskeyConsent.tsx: the site the
/// OS verified, the requested capabilities and the identity, with explicit approve and deny.
final class PasskeyConsentModel: ObservableObject {
  enum Phase: Equatable {
    case loading
    case consent
    case authorising
    case failed(String)
    case choosing
    case info(String)
  }

  @Published var phase: Phase = .loading
  @Published var choices: [(pubky: String, name: String)] = []
  @Published var rpId = ""
  @Published var identityName = ""
  @Published var pubky = ""
  @Published var capabilities: [(path: String, permission: String)] = []
}

struct PasskeyConsentView: View {
  @ObservedObject var model: PasskeyConsentModel
  let onApprove: () -> Void
  let onDeny: () -> Void
  let onChoose: (String) -> Void

  private var phase: PasskeyConsentModel.Phase { model.phase }
  private var capabilities: [(path: String, permission: String)] { model.capabilities }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.title2.bold())
      switch phase {
      case .info(let message):
        Text(message).foregroundStyle(.secondary)
        Spacer()
        Button("Done", action: onDeny).buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
      case .choosing:
        Text("Choose the pubky to sign in with.").foregroundStyle(.secondary)
        ScrollView {
          VStack(spacing: 12) {
            ForEach(model.choices, id: \.pubky) { choice in
              Button {
                onChoose(choice.pubky)
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  Text(choice.name).font(.body.weight(.semibold))
                  Text(PasskeyShared.shortPubky(choice.pubky)).font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
              }
              .buttonStyle(.plain)
            }
          }
        }
        Button("Cancel", role: .cancel, action: onDeny).frame(maxWidth: .infinity)
      case .loading:
        Spacer()
        ProgressView().frame(maxWidth: .infinity)
        Spacer()
      case .failed(let message):
        Text(message).foregroundStyle(.secondary)
        Spacer()
        Button("Close", action: onDeny).buttonStyle(.bordered).frame(maxWidth: .infinity)
      case .consent, .authorising:
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            card(title: "REQUESTING SITE") {
              Label(model.rpId, systemImage: "globe").font(.body.weight(.medium))
              Text("iOS confirmed this request comes from this site.").font(.footnote).foregroundStyle(.secondary)
            }
            card(title: "PERMISSIONS") {
              if capabilities.isEmpty {
                Text("Prove you control this pubky.").font(.subheadline)
              }
              ForEach(capabilities.indices, id: \.self) { index in
                HStack {
                  Label(capabilities[index].path, systemImage: "folder").font(.subheadline)
                  Spacer()
                  Text(capabilities[index].permission).font(.subheadline).foregroundStyle(.secondary)
                }
              }
            }
            card(title: "IDENTITY") {
              Text(model.identityName).font(.body.weight(.semibold))
              Text(PasskeyShared.shortPubky(model.pubky)).font(.footnote.monospaced()).foregroundStyle(.secondary)
            }
          }
        }
        Button(action: onApprove) {
          HStack {
            if phase == .authorising { ProgressView() }
            Text(phase == .authorising ? "Authorising…" : "Authorise").frame(maxWidth: .infinity)
          }
          .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(phase == .authorising)
        Button("Deny", role: .cancel, action: onDeny)
          .frame(maxWidth: .infinity)
          .disabled(phase == .authorising)
      }
    }
    .padding(24)
  }

  private var title: String {
    switch phase {
    case .failed: return "Sign-in request refused"
    case .info: return "Pubky Ring passkeys"
    default: return "Sign in with Pubky Ring"
    }
  }

  private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
  }

  /// "/pub/pubky.app/:rw,/pub/other/:r" → [("/pub/pubky.app/", "rw"), ("/pub/other/", "r")]
  static func parseCapabilities(_ caps: String?) -> [(path: String, permission: String)] {
    (caps ?? "").split(separator: ",").compactMap { entry in
      guard let colon = entry.lastIndex(of: ":") else { return nil }
      return (String(entry[..<colon]), String(entry[entry.index(after: colon)...]))
    }
  }
}
