import type { Pubky } from '../types/pubky';
import { PASSKEY_KNOWN_RP_IDS, PASSKEY_SNAPSHOT_VERSION } from './config';

export interface PasskeySnapshotIdentity {
	/** z-base-32 public key, no `pk:` prefix. Also the WebAuthn userHandle. */
	pubky: string;
	/** Redux store key, used to look up the secret. */
	storeKey: string;
	name: string;
	/** Set for pubkys imported from another app (Bitkit), whose secret Ring fetches from that app. */
	sourceApp?: string;
}

/**
 * Non-secret data the native providers need before Ring's JS runs: who can
 * sign in, and whether consent can be skipped. Secrets stay in the keychain.
 */
export interface PasskeySnapshot {
	version: number;
	autoAuth: boolean;
	requireDeviceAuth: boolean;
	knownRpIds: string[];
	identities: PasskeySnapshotIdentity[];
}

export const toZ32 = (pubky: string): string => pubky.replace(/^pk:/, '');

export const buildPasskeySnapshot = ({
	pubkys,
	autoAuth,
	requireDeviceAuth,
	knownRpIds = PASSKEY_KNOWN_RP_IDS,
}: {
	pubkys: Record<string, Pubky>;
	autoAuth: boolean;
	requireDeviceAuth: boolean;
	knownRpIds?: string[];
}): PasskeySnapshot => ({
	version: PASSKEY_SNAPSHOT_VERSION,
	autoAuth,
	requireDeviceAuth,
	knownRpIds,
	identities: Object.entries(pubkys)
		.map(([storeKey, pubky]) => ({
			pubky: toZ32(storeKey),
			storeKey,
			name: pubky.name ?? '',
			...(pubky.sourceApp ? { sourceApp: pubky.sourceApp } : {}),
		}))
		.sort((a, b) => a.pubky.localeCompare(b.pubky)),
});
