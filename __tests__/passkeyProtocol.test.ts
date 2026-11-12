import vectors from './fixtures/passkey/vectors.json';
import {
	base64UrlDecode,
	base64UrlEncode,
	decodeEnvelope,
	encodeEnvelope,
	hasEnvelopeMagic,
} from '../src/passkey/envelope';
import {
	isClientIdAllowed,
	parsePubkyAuthLink,
	validatePasskeyRequest,
	ENVELOPE_MAX_LIFETIME_SECONDS,
} from '../src/passkey/policy';
import { createNonceCache } from '../src/passkey/nonceCache';
import { buildPasskeySnapshot } from '../src/passkey/snapshot';

const reference = require('../scripts/passkey/protocol-reference');

const hexToBytes = (hex: string): Uint8Array => new Uint8Array(Buffer.from(hex, 'hex'));
const RP_ID = vectors.mailbox.rpId;
const NOW = vectors.envelope.input.exp - 60;

const linkFor = (overrides: Record<string, string | undefined> = {}): string => {
	const params: Record<string, string | undefined> = {
		caps: '/pub/pubky.app/:rw',
		relay: 'https://httprelay.staging.pubky.app/inbox',
		cid: RP_ID,
		cpk: '8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo',
		af: 'v1',
		epk: 'kgq7x5r3cqh8sdi4bopp7xa1kbtxwkmbh8xbxfndy5b9f9wq3g3o',
		...overrides,
	};
	const query = Object.entries(params)
		.filter(([, value]) => value !== undefined)
		.map(([key, value]) => `${key}=${encodeURIComponent(value as string)}`)
		.join('&');
	return `pubkyauth://signin_grant?${query}`;
};

const envelopeFor = (url: string, exp = vectors.envelope.input.exp, nonceByte = 1): Uint8Array =>
	encodeEnvelope({ exp, nonce: new Uint8Array(16).fill(nonceByte), url });

describe('passkey envelope', () => {
	it('matches the shared vector', () => {
		const { input } = vectors.envelope;
		const encoded = encodeEnvelope({ ...input, nonce: hexToBytes(input.nonce) });
		expect(Buffer.from(encoded).toString('hex')).toBe(vectors.envelope.hex);
		expect(base64UrlEncode(encoded)).toBe(vectors.envelope.base64url);
	});

	it('round-trips through base64url and decode', () => {
		const decoded = decodeEnvelope(base64UrlDecode(vectors.envelope.base64url));
		expect(decoded.url).toBe(vectors.envelope.input.url);
		expect(decoded.exp).toBe(vectors.envelope.input.exp);
		expect(Buffer.from(decoded.nonce).toString('hex')).toBe(vectors.envelope.input.nonce);
		expect(hasEnvelopeMagic(base64UrlDecode(vectors.envelope.base64url))).toBe(true);
	});

	it('rejects truncated, padded and foreign input', () => {
		const bytes = hexToBytes(vectors.envelope.hex);
		expect(() => decodeEnvelope(bytes.slice(0, bytes.length - 1))).toThrow();
		expect(() => decodeEnvelope(new Uint8Array([...bytes, 0]))).toThrow();
		expect(() => decodeEnvelope(new Uint8Array(40))).toThrow('Not a Pubky envelope');
		const badVersion = bytes.slice();
		badVersion[6] = 2;
		expect(() => decodeEnvelope(badVersion)).toThrow('Unsupported envelope version 2');
	});

	it('encodes base64url like Node', () => {
		for (let length = 0; length < 40; length++) {
			const bytes = new Uint8Array(length).map((_, i) => (i * 37 + length) % 256);
			expect(base64UrlEncode(bytes)).toBe(Buffer.from(bytes).toString('base64url'));
			expect(Array.from(base64UrlDecode(base64UrlEncode(bytes)))).toEqual(Array.from(bytes));
		}
	});
});

describe('passkey mailbox vectors', () => {
	it('derive the documented salt, key, channel and body', () => {
		const r = hexToBytes(vectors.mailbox.prfInputHex);
		const s = reference.prfSalt(r);
		expect(s.toString('hex')).toBe(vectors.mailbox.prfSaltHex);
		expect(reference.mailboxKey(s).toString('hex')).toBe(vectors.mailbox.keyHex);
		expect(reference.mailboxChannel(s)).toBe(vectors.mailbox.channel);
		const opened = reference.openMailbox({ s, body: Buffer.from(vectors.mailbox.bodyHex, 'hex'), rpId: RP_ID });
		expect(opened.toString('hex')).toBe(vectors.envelope.hex);
	});

	it('binds the mailbox body to the rpId', () => {
		const s = Buffer.from(vectors.mailbox.prfSaltHex, 'hex');
		expect(() =>
			reference.openMailbox({ s, body: Buffer.from(vectors.mailbox.bodyHex, 'hex'), rpId: 'evil.example' }),
		).toThrow();
	});

	it('derives the documented credential ID', () => {
		const { rpId, pubky, hex } = vectors.credentialId;
		expect(reference.credentialId(rpId, pubky).toString('hex')).toBe(hex);
	});
});

describe('passkey client ID policy', () => {
	it('requires an exact match by default', () => {
		expect(isClientIdAllowed({ clientId: 'pubky.app', rpId: 'pubky.app' })).toBe(true);
		expect(isClientIdAllowed({ clientId: 'PUBKY.app.', rpId: 'pubky.app' })).toBe(true);
		expect(isClientIdAllowed({ clientId: 'staging.pubky.app', rpId: 'pubky.app' })).toBe(false);
		expect(isClientIdAllowed({ clientId: 'pubky.app', rpId: 'evil.example' })).toBe(false);
		expect(isClientIdAllowed({ clientId: 'evilpubky.app', rpId: 'pubky.app' })).toBe(false);
	});

	it('can be relaxed to subdomains', () => {
		expect(isClientIdAllowed({ clientId: 'staging.pubky.app', rpId: 'pubky.app', policy: 'subdomain' })).toBe(true);
		expect(isClientIdAllowed({ clientId: 'evilpubky.app', rpId: 'pubky.app', policy: 'subdomain' })).toBe(false);
	});
});

describe('validatePasskeyRequest', () => {
	const validate = (envelopeBytes: Uint8Array, extra: Partial<Parameters<typeof validatePasskeyRequest>[0]> = {}) =>
		validatePasskeyRequest({ envelopeBytes, rpId: RP_ID, nowSeconds: NOW, ...extra });

	it('accepts the shared vector', () => {
		const res = validate(hexToBytes(vectors.envelope.hex), { originHost: RP_ID });
		expect(res.ok).toBe(true);
		if (res.ok) {
			expect(res.link.clientId).toBe(RP_ID);
			expect(res.link.relay).toBe('https://httprelay.staging.pubky.app/inbox');
		}
	});

	it.each([
		['expired', envelopeFor(linkFor(), NOW - 120)],
		['lifetime', envelopeFor(linkFor(), NOW + ENVELOPE_MAX_LIFETIME_SECONDS + 120)],
		['unsupported_link', envelopeFor(linkFor().replace('signin_grant', 'signin'))],
		['unsupported_link', envelopeFor(linkFor({ af: undefined }))],
		['unsupported_link', envelopeFor(linkFor({ epk: undefined }))],
		['unsupported_link', envelopeFor(`${linkFor()}&secret=abc`)],
		['insecure_relay', envelopeFor(linkFor({ relay: 'http://httprelay.pubky.app/inbox' }))],
		['client_id_mismatch', envelopeFor(linkFor({ cid: 'pubky.app' }))],
		['client_id_mismatch', envelopeFor(linkFor({ cid: undefined }))],
		['malformed', new Uint8Array([1, 2, 3])],
	])('rejects %s', (reason, bytes) => {
		expect(validate(bytes)).toEqual({ ok: false, reason });
	});

	it('rejects a browser origin that does not match the rpId', () => {
		expect(validate(envelopeFor(linkFor()), { originHost: 'evil.example' })).toEqual({
			ok: false,
			reason: 'origin_mismatch',
		});
	});

	it('rejects a replayed nonce', () => {
		const storage = new Map<string, string>();
		const cache = createNonceCache(
			{ getString: key => storage.get(key), set: (key, value) => storage.set(key, value) },
			() => NOW,
		);
		const bytes = envelopeFor(linkFor());
		const first = validate(bytes, { hasSeenNonce: cache.has });
		expect(first.ok).toBe(true);
		if (first.ok) cache.remember(first.envelope.nonce, first.envelope.exp);
		expect(validate(bytes, { hasSeenNonce: cache.has })).toEqual({ ok: false, reason: 'replayed' });
	});
});

describe('passkey nonce cache', () => {
	it('forgets nonces once their envelope has expired', () => {
		const storage = new Map<string, string>();
		let now = 1000;
		const cache = createNonceCache(
			{ getString: key => storage.get(key), set: (key, value) => storage.set(key, value) },
			() => now,
		);
		const nonce = new Uint8Array(16).fill(7);
		cache.remember(nonce, 1100);
		expect(cache.has(nonce)).toBe(true);
		now = 1200;
		expect(cache.has(nonce)).toBe(false);
	});
});

describe('parsePubkyAuthLink', () => {
	it('reads the SDK grant parameters', () => {
		expect(parsePubkyAuthLink(vectors.envelope.input.url)).toEqual({
			route: 'signin_grant',
			clientId: RP_ID,
			relay: 'https://httprelay.staging.pubky.app/inbox',
			approvalFormat: 'v1',
			ephemeralPublicKey: 'kN-sSW2BOQClhwV8qF4DVOq9xrQHJvhvF-zU_W-KbTQ',
			clientPublicKey: 'qdw49yskax4cd33s85ojn45qom1hb7unn77d1eou3shnnjd95phy',
			hasSecret: false,
			expectedSigner: undefined,
		});
		expect(parsePubkyAuthLink('https://example.com')).toBeNull();
	});
});

describe('buildPasskeySnapshot', () => {
	it('lists z32 pubkys without secrets', () => {
		const snapshot = buildPasskeySnapshot({
			pubkys: {
				'pk:bbbb': { name: 'Bob' } as never,
				aaaa: { name: 'Alice', sourceApp: 'to.bitkit' } as never,
			},
			autoAuth: false,
			requireDeviceAuth: true,
			knownRpIds: ['pubky.app'],
		});
		expect(snapshot).toEqual({
			version: 1,
			autoAuth: false,
			requireDeviceAuth: true,
			alwaysShowAuthDetails: false,
			knownRpIds: ['pubky.app'],
			identities: [
				{ pubky: 'aaaa', storeKey: 'aaaa', name: 'Alice', sourceApp: 'to.bitkit' },
				{ pubky: 'bbbb', storeKey: 'pk:bbbb', name: 'Bob' },
			],
		});
	});

	it('carries the names and details preference the iOS consent sheet shows', () => {
		const snapshot = buildPasskeySnapshot({
			pubkys: { 'pk:bbbb': { name: '' } as never },
			autoAuth: false,
			requireDeviceAuth: false,
			alwaysShowAuthDetails: true,
			displayNames: { 'pk:bbbb': 'pubky #2' },
			knownRpIds: [],
		});
		expect(snapshot.alwaysShowAuthDetails).toBe(true);
		expect(snapshot.identities).toEqual([
			{ pubky: 'bbbb', storeKey: 'pk:bbbb', name: '', displayName: 'pubky #2' },
		]);
	});
});
