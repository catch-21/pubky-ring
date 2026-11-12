import { Buffer } from 'buffer';
import { sha256 } from '@noble/hashes/sha2';
import { base64UrlDecode, base64UrlEncode, decodeEnvelope } from './envelope';
import { cancelPasskeyRequest } from './native';
import { parsePubkyAuthLink } from './policy';
import type { PasskeyRequestError } from './request';

/**
 * Refusal reports. WebAuthn gives the page only NotAllowedError (Safari) or
 * NotReadableError (Chrome) when Ring refuses, so Ring first posts the reason
 * to the request's own relay, on a channel derived from the envelope nonce,
 * and the page reads it once the ceremony fails. Best effort, and separate
 * from the grant and the assertion. Twin of
 * ios/PubkyRingCredentialProvider/PasskeyReport.swift and
 * scripts/passkey/protocol-reference.js.
 */
export const REPORT_DOMAIN = 'pubky-ring-webauthn-report-v1';
export const REPORT_TIMEOUT_MS = 3000;

export type PasskeyRefusalReason = PasskeyRequestError | 'approval_failed';

export const reportChannel = (nonce: Uint8Array): string =>
	base64UrlEncode(
		sha256(Buffer.concat([Buffer.from(`${REPORT_DOMAIN}/channel`, 'utf8'), Buffer.from(nonce)])),
	);

export const reportBody = (reason: PasskeyRefusalReason): string => JSON.stringify({ v: 1, reason });

/** Where to report a refusal of this base64url envelope: only to an https relay named by its link. */
export const reportUrlFor = (envelope64: string): string | null => {
	try {
		const envelope = decodeEnvelope(base64UrlDecode(envelope64));
		const relay = parsePubkyAuthLink(envelope.url)?.relay;
		if (!relay || !/^https:\/\/[^?#]+$/i.test(relay)) return null;
		return `${relay.replace(/\/+$/, '')}/${reportChannel(envelope.nonce)}`;
	} catch {
		return null;
	}
};

export const postRefusalReport = async (
	url: string,
	reason: PasskeyRefusalReason,
	{ timeoutMs = REPORT_TIMEOUT_MS, fetchImpl = fetch }: { timeoutMs?: number; fetchImpl?: typeof fetch } = {},
): Promise<boolean> => {
	const controller = new AbortController();
	const timer = setTimeout(() => controller.abort(), timeoutMs);
	try {
		const res = await fetchImpl(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: reportBody(reason),
			signal: controller.signal,
		});
		return res.ok;
	} catch {
		return false;
	} finally {
		clearTimeout(timer);
	}
};

/**
 * Ends a request Ring will not sign, as a failure rather than a cancellation,
 * after reporting the reason to the request's relay.
 */
export const refusePasskeyRequest = async ({
	requestId,
	envelope,
	reason,
	fetchImpl,
}: {
	requestId: string;
	/** base64url E from the launch options. */
	envelope: string;
	reason: PasskeyRefusalReason;
	fetchImpl?: typeof fetch;
}): Promise<boolean> => {
	const url = reportUrlFor(envelope);
	if (url) await postRefusalReport(url, reason, { fetchImpl });
	return cancelPasskeyRequest(requestId, reason, { refused: true });
};
