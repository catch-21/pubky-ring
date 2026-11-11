/**
 * Passkey sign-in configuration. Decisions are recorded in
 * docs/passkey-provider/PLAN.md section 14.
 */

/**
 * rpIds Ring registers iOS passkey identities for, so Ring appears in the
 * passkey sheet on these sites without a page-initiated enrolment
 * (decision 3). Add the Vercel demo host here, for example
 * 'pubky-app-git-cursor-ring-passkey-signin-d16a-<team>.vercel.app'.
 * Android needs no list: it offers Ring for every Pubky envelope.
 */
export const PASSKEY_KNOWN_RP_IDS: string[] = ['pubky.app', 'staging.pubky.app'];

/** Mailbox relay used when https://{rpId}/.well-known/pubky-auth.json is missing (decision 6). */
export const DEFAULT_MAILBOX_RELAY = 'https://httprelay.pubky.app/inbox';

/** Snapshot schema shared with the native providers (Kotlin and Swift). */
export const PASSKEY_SNAPSHOT_VERSION = 1;

/** iOS releases that ship third-party passkey providers, and PRF inputs for them (decision 1). */
export const IOS_PASSKEY_PROVIDER_MIN_VERSION = 17;
export const IOS_PASSKEY_PRF_MIN_VERSION = 18;

/** Android Credential Manager provider services need API 34 (Android 14). */
export const ANDROID_PASSKEY_PROVIDER_MIN_API = 34;
