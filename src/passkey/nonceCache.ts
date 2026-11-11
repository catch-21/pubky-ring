import { base64UrlEncode } from './envelope';
import { ENVELOPE_CLOCK_SKEW_SECONDS } from './policy';

export interface NonceStorage {
	getString: (key: string) => string | undefined;
	set: (key: string, value: string) => void;
}

const STORAGE_KEY = 'passkey.seenNonces';

/**
 * Remembers envelope nonces until their envelope expires, so a replayed E is
 * refused (PLAN.md section 8.4).
 */
export const createNonceCache = (storage: NonceStorage, now: () => number = () => Math.floor(Date.now() / 1000)) => {
	const read = (): Record<string, number> => {
		try {
			const parsed = JSON.parse(storage.getString(STORAGE_KEY) ?? '{}');
			return parsed && typeof parsed === 'object' ? parsed : {};
		} catch {
			return {};
		}
	};

	const prune = (entries: Record<string, number>): Record<string, number> => {
		const cutoff = now() - ENVELOPE_CLOCK_SKEW_SECONDS;
		return Object.fromEntries(Object.entries(entries).filter(([, exp]) => exp >= cutoff));
	};

	return {
		has: (nonce: Uint8Array): boolean => base64UrlEncode(nonce) in prune(read()),
		remember: (nonce: Uint8Array, exp: number): void => {
			const entries = prune(read());
			entries[base64UrlEncode(nonce)] = exp;
			storage.set(STORAGE_KEY, JSON.stringify(entries));
		},
	};
};

export type NonceCache = ReturnType<typeof createNonceCache>;
