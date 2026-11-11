# Pubky Ring passkey sign-in: MVP build, test and deploy guide

This is the companion to [PLAN.md](PLAN.md). It records what was built, how far each part has been checked, and the steps needed to run it on real phones and to host the demo.

## Status

| Part | State |
|---|---|
| Shared protocol (envelope, `cid` policy, iOS mailbox, credential IDs) | Built in TypeScript (Ring and pubky-app), Kotlin and Swift. All three agree with the shared vectors in `__tests__/fixtures/passkey/vectors.json`. |
| Android provider | Built and run on an emulator. Ring appears in Chrome's passkey sheet, shows the consent screen, refuses a wrong `cid`, and returns `NotAllowedError` on deny or back. Final approval through the relay has not been run (see [What has not been verified](#what-has-not-been-verified)). |
| iOS provider extension | Source and project script written. Not compiled against the iOS SDK, because there is no Mac here. The protocol code compiles and passes the vectors on Linux. |
| pubky-app sign-in | Built on the fork branch with SDK 0.18.0. The mobile Ring button runs the passkey flow, and the deep link remains the fallback. The pubky-app unit tests pass. Not yet pushed to the fork: see [pubky-app branch](#pubky-app-branch). |
| Vercel demo | Not deployed. The steps are in [Demo on Vercel Hobby](#demo-on-vercel-hobby). |

No homeserver or Pubky SDK changes were needed.

## Branches

- **Ring:** `cursor/passkey-mvp-d16a` in `catch-21/pubky-ring`, cut from upstream `main` at `b1f9157`.
- **pubky-app:** `cursor/ring-passkey-signin-d16a`, cut from upstream `dev` at `0e427866`. The Cursor bot has no write access to `catch-21/pubky-app`, so the branch is delivered as patches in [`pubky-app-patches/`](pubky-app-patches).

### pubky-app branch

The patches apply cleanly to `0e427866` and reproduce the branch exactly. To publish it:

```bash
git clone https://github.com/catch-21/pubky-app.git && cd pubky-app
git fetch https://github.com/pubky/pubky-app.git dev
git checkout -b cursor/ring-passkey-signin-d16a 0e427866
git am /path/to/pubky-ring/docs/passkey-provider/pubky-app-patches/*.patch
git push -u origin cursor/ring-passkey-signin-d16a
```

Alternatively, install the Cursor GitHub app on `catch-21/pubky-app` so a later run can push it.

The six commits are:

1. Upgrade `@synonymdev/pubky` to 0.18.0.
2. Passkey sign-in: `src/libs/passkey/` (envelope, mailbox, WebAuthn request), `AuthController.getPasskeyAuthUrl()`, a `passkey` option on the grant flow (`af=v1`), and the `usePasskeyAuth` hook.
3. `SignIn`: on mobile, the Ring button runs the passkey flow when the browser supports it. Otherwise it uses the existing deep link.
4. `/passkey-spike`: a device test page, not served when `PUBKY_RUNTIME_ENV=production`.
5. `/.well-known/pubky-auth.json`, `/.well-known/assetlinks.json` and `/.well-known/apple-app-site-association` route handlers.
6. The grant uses the app's own client ID, and the passkey path is offered only where that client ID is the page's host.

## How a sign-in runs

1. The page starts a Pubky grant flow (`signin_grant`, `af=v1`) and packs the `pubkyauth://` link into the request envelope `E` (PLAN.md section 4.4).
2. It calls `navigator.credentials.get()` with `rpId` set to its own host, and Ring is chosen in the system passkey sheet:
   - On Android, `E` is the WebAuthn challenge.
   - On iOS, the page also encrypts `E` into the relay mailbox under a key derived from its PRF input (PLAN.md section 4.5).
3. Ring validates `E`:
   - The lifetime is at most 300 seconds (plus 30 seconds of clock skew), and the nonce has not been seen before.
   - The link is a `signin_grant` with `af=v1`, `epk` and `cpk`, and no `secret`.
   - The relay is `https`.
   - On Android, the host of the browser-verified origin equals the rpId.
   - `cid` equals the rpId exactly.
4. Ring shows consent (skipped when Auto Auth is on, as with QR scanning). It then signs the grant approval, posts it to the relay, and returns a passkey assertion whose `userHandle` is the pubky.
5. The page receives the session from the relay. It adopts the session only if the session's pubky equals the assertion's `userHandle`.

## Files

### Ring

| Area | Files |
|---|---|
| Shared JS | `src/passkey/`: `envelope.ts`, `policy.ts` (`CLIENT_ID_POLICY`), `request.ts`, `nonceCache.ts`, `snapshot.ts`, `usePasskeySnapshotSync.ts`, `native.ts`, `config.ts`, `PasskeyConsentRoot.tsx`. Also `src/screens/PasskeyConsent.tsx`, `src/components/PasskeySettingsSection.tsx`, `index.js` (`PubkyPasskeyConsent`), and i18n `passkey.*` |
| Android | `android/app/src/main/java/com/pubkyring/passkey/`: `RingCredentialProviderService.kt`, `PasskeyConsentActivity.kt`, `PubkyPasskeyModule.kt`, `PubkyWebAuthn.kt`, `CeremonyKeyStore.kt`, `PasskeySnapshotStore.kt`. Also `AndroidManifest.xml`, `res/xml/pubky_credential_provider.xml`, `res/values*/bools.xml`, `assets/passkey_privileged_browsers.json`, and `androidx.credentials` 1.5.0 |
| iOS extension | `ios/PubkyRingCredentialProvider/`: `CredentialProviderViewController.swift`, `PasskeyConsentView.swift`, `PasskeyApprover.swift`, `PasskeyEnvelope.swift`, `PasskeyPolicy.swift`, `PasskeyMailbox.swift`, `PasskeyShared.swift`, `CeremonyKeys.swift`, `WebAuthnEncoding.swift`, `Info.plist`, entitlements |
| iOS app | `ios/pubkyring/PubkyPasskey.m` (snapshot, identity store, provider status), `SharedPubky.m`, `Info.plist`, `pubkyring.entitlements`, `ios/Config/Signing.xcconfig`, `project.pbxproj` |
| Scripts | `scripts/passkey/add-ios-credential-provider.rb`, `generate-vectors.js`, `protocol-reference.js`, `swift-vector-check/`, `emulator-check.html` |
| Tests | `__tests__/passkeyProtocol.test.ts`, `__tests__/fixtures/passkey/vectors.json` |

`passkey_privileged_browsers.json` is a copy of Google's privileged browser allowlist (<https://www.gstatic.com/gpm-passkeys-privileged-apps/apps.json>). Ring uses it to trust the origin a browser reports. Refresh it from that URL from time to time.

### Changing the `cid` rule later

Decision 4 is "`cid` equals the rpId exactly". The rule lives in one place per platform, each with a `subdomain` mode already written:

- `CLIENT_ID_POLICY` in `src/passkey/policy.ts` (used by Android);
- `PasskeyPolicy.clientIdPolicy` in `ios/PubkyRingCredentialProvider/PasskeyPolicy.swift`.

To relax the rule, switch both to `'subdomain'` / `.subdomain`. Separately, pubky-app's `isPasskeyClientIdUsable()` in `src/config/passkey.ts` decides whether the page offers the passkey at all.

## Android phone

Requirements:

- Android 14 or later (the provider service needs API 34).
- Chrome, with a screen lock set on the phone.
- A pubky in Ring that is signed up on the same homeserver as the web app it signs in to. Ring offers only identities that can authorise, just as QR scanning does. See [Homeserver and Ring build](#homeserver-and-ring-build).

Steps:

1. **Build and install.**
   - For the staging demo, use a debug build (`yarn start`, then `yarn android`).
   - For a standalone APK, run `cd android && ./gradlew :app:assembleRelease -PPUBKYRING_DEBUG_SIGNING=true`, then `adb install -r app/build/outputs/apk/release/app-universal-release.apk`. This APK signs up on the production homeserver.
2. **Prepare an identity.** Open Ring and create or import a pubky, and finish sign-up.
3. **Enable Ring as a provider.** Go to Settings > Passwords, passkeys & accounts (the wording varies by manufacturer) and turn on Pubky Ring. Ring's own Settings screen has a passkey section that shows the status and opens this page.
4. **Check Chrome.**
   - Recent Chrome uses Android's Credential Manager for passkeys by default.
   - On older Chrome, if only Google Password Manager appears, enable `chrome://flags/#web-authentication-android-credential-management` and restart Chrome. This was needed on Chrome 124 in the emulator.
   - Chrome's "Autofill services" setting may also need "Autofill using another service" (not checked).
5. **Sign in.** Open the demo in Chrome and tap the Pubky Ring button. Choose Pubky Ring in the sheet, check the site and permissions, and swipe to authorise.
6. **Debugging.** `adb logcat -s PubkyPasskey` logs each Pubky request the provider sees. `adb logcat ReactNativeJS:V` shows the consent screen's JS logs.

### Emulator check

This reproduces the checks behind the screenshots in the pull request.

1. Create an AVD: API 35, Google Play image, x86_64.
2. Set a screen lock: `adb shell locksettings set-pin 1234`.
3. In Chrome, enable the flag from step 4 above.
4. Install the APK, then enable Pubky Ring in Settings.
5. Serve the page from your machine:
   - `cd scripts/passkey && python3 -m http.server 8080`
   - `adb reverse tcp:8080 tcp:8080`
   - In Chrome on the emulator, open `http://localhost:8080/emulator-check.html`. `localhost` is a secure context, so WebAuthn works over plain HTTP here.
6. Tap the two buttons:
   - **"Sign in (cid = this host)"** should show Ring in the sheet, then the consent screen.
   - **"Sign in (cid = evil.example)"** should show Ring's refusal screen.
   - Deny, back and Close should each print `NotAllowedError` on the page.

Ring lists only identities that can authorise. To see the consent screen on the emulator without a signed-up account, the identity was marked as signed up with a temporary local change, which has been reverted. Approving that identity then fails with "Homeserver not found", as expected for a key with no homeserver record.

## iPhone

Requirements:

- iOS 17 or later for the provider. The page's mailbox route needs iOS 18, because that is when iOS passes PRF inputs to providers. The app's minimum stays at iOS 15.1, and only the passkey feature is gated (decision 1).
- Xcode 16 or later.
- An Apple Developer team of your own. Do not use Synonym's team `KYH47R284B`. A paid membership is the safe choice for App Groups and the AutoFill Credential Provider capability (not checked with a free team).

Steps:

1. **Signing values.** Copy the four keys from `ios/Config/Signing.xcconfig` into `ios/Config/Signing.local.xcconfig` (git-ignored) and fill them in:

   ```text
   RING_DEVELOPMENT_TEAM = ABCDE12345
   RING_APP_BUNDLE_ID = com.yourname.pubkyring
   RING_PASSKEY_EXTENSION_ID = $(RING_APP_BUNDLE_ID).CredentialProvider
   RING_APP_GROUP = group.com.yourname.pubkyring
   ```

2. **Apple identifiers.** In the developer portal, create the App Group, and an App ID for each bundle ID with the App Groups and AutoFill Credential Provider capabilities. Assign the group to both App IDs. Xcode's automatic signing can create these for you, but check that it did.
3. **Dependencies and the extension target.**

   ```bash
   yarn install
   bundle install
   bundle exec ruby scripts/passkey/add-ios-credential-provider.rb
   cd ios && bundle exec pod install
   ```

   The script adds the `PubkyRingCredentialProvider` target:
   - It compiles the extension sources plus `pubkycore.swift` from `@synonymdev/react-native-pubky`, and links `PubkyCore.xcframework` statically.
   - It targets iOS 17.0 and takes its IDs from the xcconfig.
   - It embeds the extension in the app.

   It is safe to rerun, and its `project.pbxproj` changes are yours to commit. Undo with `git checkout ios/pubkyring.xcodeproj/project.pbxproj`.
4. **Build.** Open `ios/pubkyring.xcworkspace` and run the `pubkyring` scheme on a device.
   - The extension has never been compiled against the iOS SDK.
   - Expect to fix a few names on first build, most likely the iOS 18 PRF reads in `CredentialProviderViewController.swift`: `request.assertionExtensionInput?.prf?.inputValues?.saltInput1` and `requestParameters.extensionInput?.prf?.inputValues?.saltInput1`.
   - Everything else uses iOS 17 APIs.
5. **Enable the provider.** Open Ring, then create or import a pubky and finish sign-up. This writes the snapshot that the extension reads. Then go to:
   - iOS 18: Settings > General > AutoFill & Passwords;
   - iOS 17: Settings > Passwords > Password Options.

   Turn on Pubky Ring there.
6. **Make Ring appear for the demo site.** iOS shows a provider only for rpIds where it has stored identities. Either:
   - add the Vercel host to `PASSKEY_KNOWN_RP_IDS` in `src/passkey/config.ts` and rebuild; or
   - open `https://<host>/passkey-spike` and use its registration button, which runs `navigator.credentials.create()` with Ring.
7. **Sign in.** In Safari, open the demo, or `/passkey-spike` for a detailed log.
   - The default route is the PRF mailbox.
   - `?ringTransport=allowCredentials` tries the undocumented iOS 17 route instead.

Notes:

- Identities adopted from Bitkit live in the `pubky.shared` keychain group under Synonym's team, so a build signed with another team cannot read them. Use identities created in Ring.
- The extension's protocol code can be checked without Xcode: `scripts/passkey/swift-vector-check/run.sh` (Swift 5.9 or later; it uses swift-crypto in place of CryptoKit).

## Demo on Vercel Hobby

I could not deploy this myself: the pubky-app branch is not pushed yet, and this environment has no Vercel account. The steps are:

1. **Push the branch.** Push the pubky-app branch to `catch-21/pubky-app` (see [pubky-app branch](#pubky-app-branch)).
2. **Import the project.** In Vercel, choose Add New > Project, then import `catch-21/pubky-app`.
   - Framework preset: Next.js.
   - Build command: the default (`npm run build`).
   - Node version: 24 (the repository's `.nvmrc`).
3. **Pick the deployment.** Either set the Production Branch (Settings > Git) to `cursor/ring-passkey-signin-d16a`, or use that branch's preview deployment.
   - The host is the rpId and the `cid`, so choose one stable host, such as `pubky-ring-demo.vercel.app` (Settings > Domains), and use it everywhere below.
   - Hobby preview URLs change with each deployment, but the branch alias (`<project>-git-<branch>-<team>.vercel.app`) stays the same.
   - Vercel Authentication (Deployment Protection) is on for previews by default. Turn it off for this project, or the phone will see a Vercel login page.
4. **Environment variables.** Under Settings > Environment Variables, set these for the environment you deploy:

   | Variable | Value |
   |---|---|
   | `PUBKY_RUNTIME_NEXUS_URL` | `https://nexus.staging.pubky.app` |
   | `PUBKY_RUNTIME_CDN_URL` | `https://nexus.staging.pubky.app/static` |
   | `PUBKY_RUNTIME_HOMESERVER` | `ufibwbmed6jeq9k4p583go95wofakh9fwpp4k734trq79pd9u1uy` |
   | `PUBKY_RUNTIME_HOMESERVER_URL` | `https://homeserver.staging.pubky.app` |
   | `PUBKY_RUNTIME_HOMEGATE_URL` | `https://homegate.staging.pubky.app` |
   | `PUBKY_RUNTIME_DEFAULT_HTTP_RELAY` | `https://httprelay.staging.pubky.app/inbox` |
   | `PUBKY_RUNTIME_PKARR_RELAYS` | `["https://pkarr.pubky.app","https://pkarr.pubky.org"]` |
   | `PUBKY_RUNTIME_TESTNET` | `false` |
   | `PUBKY_RUNTIME_ENV` | `staging` |
   | `PUBKY_RUNTIME_AUTH_CLIENT_ID` | the host, for example `pubky-ring-demo.vercel.app` |
   | `PASSKEY_ANDROID_CERT_SHA256` | optional; see below |
   | `PASSKEY_IOS_APP_IDS` | optional, for example `ABCDE12345.com.yourname.pubkyring` |

   - The first nine are pubky-app's staging values from `.env.example`. The server refuses to start without all of them.
   - `PUBKY_RUNTIME_AUTH_CLIENT_ID` is essential. pubky-app saves only grants issued to its own client ID, and Ring accepts only a `cid` equal to the host. If they differ, the page does not offer the passkey and keeps the deep link. `/passkey-spike` reports this as `clientIdMatchesHost: false`.
5. **Deploy and check:**
   - `https://<host>/.well-known/pubky-auth.json` returns `{"mailboxRelay":"https://httprelay.staging.pubky.app/inbox"}`;
   - `https://<host>/passkey-spike` loads.
6. **Tell Ring about the host (iOS only).** Add the host to `PASSKEY_KNOWN_RP_IDS` in Ring's `src/passkey/config.ts` and rebuild. Android needs nothing.

About the association files:

- `assetlinks.json` and `apple-app-site-association` are served as decision 8 asks. They are not needed for browser sign-in: browsers prove the origin themselves (PLAN.md section 3).
- They matter only if a native app later calls the same flow.
- They are empty until configured. `PASSKEY_ANDROID_CERT_SHA256` takes comma-separated SHA-256 signing certificate fingerprints. The fingerprint of the repository's `android/app/debug.keystore` is `FA:C6:17:45:DC:09:03:78:6F:B9:ED:E6:2A:96:2B:39:9F:73:48:F0:BB:6F:89:9B:83:32:66:75:91:03:3B:9C`.
- `PASSKEY_ANDROID_PACKAGE` defaults to `to.pubky.ring`.

### Homeserver and Ring build

A staging deploy (`PUBKY_RUNTIME_ENV=staging`) rejects keys whose PKARR record does not name the staging homeserver. This is pubky-app's existing staging guard, and it also applies to passkey sign-in. Ring chooses its homeserver from the build type (`IS_STAGING = __DEV__`):

- Debug builds sign up on the staging homeserver. Use them with the staging deploy above.
- Release builds sign up on the production homeserver. Their identities are refused by a staging deploy with "This key is not linked to this staging deploy homeserver".
- To sign in with a production identity, the deploy needs pubky-app's production network values and `PUBKY_RUNTIME_ENV=production`. That hides `/passkey-spike`.

## What was verified

- **Ring:**
  - Jest: 48 suites and 496 tests pass, including 25 passkey protocol tests.
  - `tsc --noEmit` passes.
  - ESLint reports no errors; its two warnings are in untouched upstream files.
- **pubky-app:**
  - `npm test`: 1,031 files, with 18,111 tests passing.
  - `tsc` and ESLint are clean on the changed files.
  - The passkey tests cover the shared vectors, the request routes, assertion parsing, support gating (including the client ID check), the association files, and the hook: adopt on a matching `userHandle`, refuse on a mismatch, cancellation, and Safari's second tap.
- **Android release APK:** built (`assembleRelease`, debug-signed).
- **Android emulator** (API 35, Chrome 124 with the flag):
  - The provider registers.
  - Ring's settings show it as enabled.
  - Ring appears in the passkey sheet.
  - Consent shows the browser-verified site and the requested permissions.
  - A wrong `cid` is refused.
  - Deny, back and Close return `NotAllowedError` to the page.
- **iOS:**
  - All extension sources parse with Swift 6.0.3.
  - The envelope, policy, mailbox, credential ID and WebAuthn encoding code compiles and passes 29 vector checks on Linux.
  - The project script runs cleanly and idempotently with `xcodeproj` 1.25.1 and 1.28.1.

## What has not been verified

- **Android approval end to end:** approve, relay post, assertion, then pubky-app adopting the session. This needs a signed-up identity on the homeserver the web app uses, and the emulator had none.
- **iOS on a device:**
  - building the extension;
  - its appearance in the passkey sheet;
  - PRF inputs reaching the provider;
  - whether iOS hands providers the raw PRF input or the hashed salt. Ring tries both readings.
  - the undocumented iOS 17 `allowCredentials` route;
  - extension memory use while the Rust core runs.
- **pubky-app on Vercel:** the deployment itself, and the deep-link fallback in real mobile browsers.
- **Other Android browsers:** Firefox and Samsung Internet.
