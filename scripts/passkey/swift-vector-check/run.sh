#!/usr/bin/env bash
# Checks the iOS extension's protocol code against __tests__/fixtures/passkey/vectors.json, and its
# consent sheet ports (strings, AuthSummary, display helpers, icons, Facehash) against the app's.
# Runs on macOS or Linux with Swift 5.9+; swift-crypto stands in for CryptoKit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
src="$root/ios/PubkyRingCredentialProvider"
work="${TMPDIR:-/tmp}/pubky-swift-vector-check"
rm -rf "$work/Sources"
mkdir -p "$work/Sources/VectorCheck"
cp "$here/Package.swift" "$work/Package.swift"
cp "$here/main.swift" "$work/Sources/VectorCheck/main.swift"
for name in PasskeyEnvelope PasskeyPolicy PasskeyMailbox PasskeyShared WebAuthnEncoding RingStrings RingAuthRequest RingGeometry; do
  {
    printf '#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'
    sed -e 's/^import CryptoKit$/import Crypto/' \
      -e 's/FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)/URL(fileURLWithPath: $0)/' \
      "$src/$name.swift"
  } > "$work/Sources/VectorCheck/$name.swift"
done
cd "$work"
swift run -c debug VectorCheck "$root/__tests__/fixtures/passkey/vectors.json"
