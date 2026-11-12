import type { Dispatch } from 'redux';
import { Result, err, ok } from '@synonymdev/result';
import { createMMKV } from 'react-native-mmkv';
import { createConfirmAuthPayload } from '../utils/actions/authAction';
import { InputAction, parseInput } from '../utils/inputParser';
import { performAuth } from '../utils/pubky';
import { getAuthorizedGrantCountFromStore, getStore } from '../utils/store-helpers';
import { syncAuthorizedGrantsAfterAuth } from '../utils/authorizedGrants';
import { getAuthorizablePubkys } from '../store/selectors/pubkySelectors';
import { getRequireDeviceAuth } from '../store/selectors/settingsSelectors';
import type { ConfirmAuthPayload } from '../sheets/types';
import { base64UrlDecode, PubkyEnvelope } from './envelope';
import { PasskeyRejectReason, validatePasskeyRequest } from './policy';
import { createNonceCache, NonceCache } from './nonceCache';
import { toZ32 } from './snapshot';
import { completePasskeyRequest } from './native';

/** Initial props the Android provider passes to the PubkyPasskeyConsent surface. */
export interface PasskeyRequestProps {
	requestId: string;
	/** rpId from the browser's request; Chrome has already checked it against the origin. */
	rpId: string;
	/** Host of CallingAppInfo.getOrigin() for an allowlisted browser. */
	originHost?: string;
	/** base64url E, taken from the WebAuthn challenge. */
	envelope: string;
	/** z-base-32 pubky of the entry the user picked in the OS sheet. */
	pubky: string;
}

export type PasskeyRequestError = PasskeyRejectReason | 'unknown_pubky' | 'invalid_link';

export class PasskeyRequestRejection extends Error {
	readonly code: PasskeyRequestError;

	constructor(code: PasskeyRequestError, message: string = code) {
		super(message);
		this.code = code;
	}
}

export interface PreparedPasskeyRequest {
	requestId: string;
	rpId: string;
	pubky: string;
	storeKey: string;
	envelope: PubkyEnvelope;
	payload: ConfirmAuthPayload;
}

let nonceCache: NonceCache | undefined;
const getNonceCache = (): NonceCache => {
	nonceCache ??= createNonceCache(createMMKV({ id: 'pubky-passkey' }));
	return nonceCache;
};

export const preparePasskeyRequest = async (
	props: PasskeyRequestProps,
	{ nowSeconds = Math.floor(Date.now() / 1000), cache = getNonceCache() }: { nowSeconds?: number; cache?: NonceCache } = {},
): Promise<Result<PreparedPasskeyRequest>> => {
	const fail = (code: PasskeyRequestError): Result<PreparedPasskeyRequest> => err(new PasskeyRequestRejection(code));

	let envelopeBytes: Uint8Array;
	try {
		envelopeBytes = base64UrlDecode(props.envelope);
	} catch {
		return fail('malformed');
	}
	const validation = validatePasskeyRequest({
		envelopeBytes,
		rpId: props.rpId,
		originHost: props.originHost,
		nowSeconds,
		hasSeenNonce: cache.has,
	});
	if (!validation.ok) return fail(validation.reason);

	const authorizable = getAuthorizablePubkys(getStore());
	const storeKey = Object.keys(authorizable).find(key => toZ32(key) === props.pubky);
	if (!storeKey) return fail('unknown_pubky');

	const parsed = await parseInput(validation.envelope.url, 'deeplink');
	if (parsed.action !== InputAction.Auth || parsed.data.action !== InputAction.Auth) {
		return fail('invalid_link');
	}
	const payload = await createConfirmAuthPayload({ data: parsed.data, pubky: storeKey });
	if (payload.isErr()) {
		return err(new PasskeyRequestRejection('invalid_link', payload.error.message));
	}

	return ok({
		requestId: props.requestId,
		rpId: props.rpId,
		pubky: props.pubky,
		storeKey,
		envelope: validation.envelope,
		payload: payload.value,
	});
};

/**
 * Signs the grant, posts it to the relay (performAuth, as for a QR scan) and
 * then hands the WebAuthn assertion back to the OS. `onApproved` runs between
 * the two, so the consent screen can show its success state first.
 */
export const approvePasskeyRequest = async ({
	request,
	dispatch,
	approvedCapabilities,
	signal,
	cache = getNonceCache(),
	onApproved,
}: {
	request: PreparedPasskeyRequest;
	dispatch: Dispatch;
	approvedCapabilities?: string;
	signal?: AbortSignal;
	cache?: NonceCache;
	onApproved?: () => Promise<void>;
}): Promise<Result<string>> => {
	if (cache.has(request.envelope.nonce)) return err('replayed');
	const currentCount = getAuthorizedGrantCountFromStore(request.storeKey);
	const res = await performAuth({
		pubky: request.storeKey,
		authUrl: request.payload.authUrl,
		dispatch,
		approvedCapabilities,
		signal,
	});
	if (res.isErr()) return res;
	cache.remember(request.envelope.nonce, request.envelope.exp);
	syncAuthorizedGrantsAfterAuth({
		pubky: request.storeKey,
		dispatch,
		currentCount,
		isGrantAuth: true,
	}).then();
	await onApproved?.();
	const completed = await completePasskeyRequest({
		requestId: request.requestId,
		pubky: request.pubky,
		userVerified: getRequireDeviceAuth(getStore()),
	});
	return completed ? ok('success') : err('complete_failed');
};
