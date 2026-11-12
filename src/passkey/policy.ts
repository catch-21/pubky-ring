import { decodeEnvelope, PubkyEnvelope } from './envelope';

/**
 * How a request's client ID (`cid`) must relate to the WebAuthn rpId that the
 * OS verified. James chose 'exact' (PLAN.md section 14, decision 4). Switch to
 * 'subdomain' to also accept, for example, cid `staging.pubky.app` at rpId
 * `pubky.app`. The Swift twin lives in ios/PubkyRingCredentialProvider/PasskeyPolicy.swift.
 */
export type ClientIdPolicy = 'exact' | 'subdomain';
export const CLIENT_ID_POLICY: ClientIdPolicy = 'exact';

export const ENVELOPE_MAX_LIFETIME_SECONDS = 300;
export const ENVELOPE_CLOCK_SKEW_SECONDS = 30;

const normaliseHost = (host: string): string => host.trim().toLowerCase().replace(/\.$/, '');

export const isHostAllowed = (host: string, rpId: string, policy: ClientIdPolicy = CLIENT_ID_POLICY): boolean => {
	const candidate = normaliseHost(host);
	const expected = normaliseHost(rpId);
	if (!candidate || !expected) return false;
	if (candidate === expected) return true;
	return policy === 'subdomain' && candidate.endsWith(`.${expected}`);
};

export const isClientIdAllowed = ({
	clientId,
	rpId,
	policy = CLIENT_ID_POLICY,
}: {
	clientId: string;
	rpId: string;
	policy?: ClientIdPolicy;
}): boolean => isHostAllowed(clientId, rpId, policy);

export interface PubkyAuthLinkFields {
	route: string;
	clientId?: string;
	relay?: string;
	approvalFormat?: string;
	ephemeralPublicKey?: string;
	clientPublicKey?: string;
	hasSecret: boolean;
	expectedSigner?: string;
}

export const parsePubkyAuthLink = (url: string): PubkyAuthLinkFields | null => {
	const match = /^pubkyauth:\/\/([a-z_]*)\/?\?(.*)$/.exec(url);
	if (!match) return null;
	const params: Record<string, string> = {};
	for (const pair of match[2].split('&')) {
		if (!pair) continue;
		const separator = pair.indexOf('=');
		const key = separator === -1 ? pair : pair.slice(0, separator);
		const value = separator === -1 ? '' : pair.slice(separator + 1);
		try {
			params[decodeURIComponent(key)] = decodeURIComponent(value.replace(/\+/g, ' '));
		} catch {
			return null;
		}
	}
	return {
		route: match[1],
		clientId: params.cid,
		relay: params.relay,
		approvalFormat: params.af,
		ephemeralPublicKey: params.epk,
		clientPublicKey: params.cpk,
		hasSecret: params.secret !== undefined,
		expectedSigner: params.spk,
	};
};

export type PasskeyRejectReason =
	| 'malformed'
	| 'expired'
	| 'lifetime'
	| 'replayed'
	| 'unsupported_link'
	| 'insecure_relay'
	| 'client_id_mismatch'
	| 'origin_mismatch';

export type PasskeyValidation =
	| { ok: true; envelope: PubkyEnvelope; link: PubkyAuthLinkFields }
	| { ok: false; reason: PasskeyRejectReason };

export interface ValidatePasskeyRequestInput {
	envelopeBytes: Uint8Array;
	rpId: string;
	/** Host of the browser-verified origin (Android). iOS passes undefined: the OS has already bound the rpId. */
	originHost?: string;
	nowSeconds: number;
	hasSeenNonce?: (nonce: Uint8Array) => boolean;
	policy?: ClientIdPolicy;
}

export const validatePasskeyRequest = ({
	envelopeBytes,
	rpId,
	originHost,
	nowSeconds,
	hasSeenNonce,
	policy = CLIENT_ID_POLICY,
}: ValidatePasskeyRequestInput): PasskeyValidation => {
	let envelope: PubkyEnvelope;
	try {
		envelope = decodeEnvelope(envelopeBytes);
	} catch {
		return { ok: false, reason: 'malformed' };
	}
	if (envelope.exp + ENVELOPE_CLOCK_SKEW_SECONDS < nowSeconds) {
		return { ok: false, reason: 'expired' };
	}
	if (envelope.exp > nowSeconds + ENVELOPE_MAX_LIFETIME_SECONDS + ENVELOPE_CLOCK_SKEW_SECONDS) {
		return { ok: false, reason: 'lifetime' };
	}
	if (hasSeenNonce?.(envelope.nonce)) {
		return { ok: false, reason: 'replayed' };
	}
	const link = parsePubkyAuthLink(envelope.url);
	if (!link) {
		return { ok: false, reason: 'malformed' };
	}
	if (
		link.route !== 'signin_grant' ||
		link.approvalFormat !== 'v1' ||
		!link.ephemeralPublicKey ||
		!link.clientPublicKey ||
		link.hasSecret
	) {
		return { ok: false, reason: 'unsupported_link' };
	}
	if (!link.relay || !/^https:\/\//i.test(link.relay)) {
		return { ok: false, reason: 'insecure_relay' };
	}
	if (!link.clientId || !isClientIdAllowed({ clientId: link.clientId, rpId, policy })) {
		return { ok: false, reason: 'client_id_mismatch' };
	}
	if (originHost !== undefined && !isHostAllowed(originHost, rpId, policy)) {
		return { ok: false, reason: 'origin_mismatch' };
	}
	return { ok: true, envelope, link };
};
