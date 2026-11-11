/**
 * Pubky WebAuthn envelope ("E").
 *
 * The web app puts E in the WebAuthn challenge (Android) or in the iOS PRF
 * mailbox. Layout, all integers big-endian:
 *
 *   magic "PKYWA1" (6) | version u8 | flags u8 | exp u32 (unix s) |
 *   nonce (16) | urlLen u16 | pubkyauth:// URL (UTF-8, urlLen bytes)
 *
 * Keep in sync with the Swift (ios/PubkyPasskeyExtension) and web
 * (pubky-app src/libs/passkey) implementations. Shared vectors live in
 * __tests__/fixtures/passkey/vectors.json.
 */

import { Buffer } from 'buffer';

export const ENVELOPE_MAGIC = 'PKYWA1';
export const ENVELOPE_VERSION = 1;
export const ENVELOPE_NONCE_LENGTH = 16;
export const ENVELOPE_HEADER_LENGTH = 6 + 1 + 1 + 4 + ENVELOPE_NONCE_LENGTH + 2;
export const ENVELOPE_MAX_URL_LENGTH = 4096;

export interface PubkyEnvelope {
	version: number;
	flags: number;
	exp: number;
	nonce: Uint8Array;
	url: string;
}

const MAGIC_BYTES = new Uint8Array([...ENVELOPE_MAGIC].map(char => char.charCodeAt(0)));

const utf8Encode = (value: string): Uint8Array => new Uint8Array(Buffer.from(value, 'utf8'));

const utf8Decode = (bytes: Uint8Array): string => {
	const text = Buffer.from(bytes).toString('utf8');
	if (Buffer.byteLength(text, 'utf8') !== bytes.length) {
		throw new Error('Envelope URL is not valid UTF-8');
	}
	return text;
};

export const hasEnvelopeMagic = (bytes: Uint8Array): boolean =>
	bytes.length >= MAGIC_BYTES.length && MAGIC_BYTES.every((byte, i) => bytes[i] === byte);

export const encodeEnvelope = ({ version = ENVELOPE_VERSION, flags = 0, exp, nonce, url }: Omit<PubkyEnvelope, 'version' | 'flags'> & Partial<Pick<PubkyEnvelope, 'version' | 'flags'>>): Uint8Array => {
	if (nonce.length !== ENVELOPE_NONCE_LENGTH) {
		throw new Error('Envelope nonce must be 16 bytes');
	}
	const urlBytes = utf8Encode(url);
	if (urlBytes.length > ENVELOPE_MAX_URL_LENGTH) {
		throw new Error('Envelope URL is too long');
	}
	const out = new Uint8Array(ENVELOPE_HEADER_LENGTH + urlBytes.length);
	const view = new DataView(out.buffer);
	out.set(MAGIC_BYTES, 0);
	out[6] = version;
	out[7] = flags;
	view.setUint32(8, exp);
	out.set(nonce, 12);
	view.setUint16(12 + ENVELOPE_NONCE_LENGTH, urlBytes.length);
	out.set(urlBytes, ENVELOPE_HEADER_LENGTH);
	return out;
};

export const decodeEnvelope = (bytes: Uint8Array): PubkyEnvelope => {
	if (!hasEnvelopeMagic(bytes)) {
		throw new Error('Not a Pubky envelope');
	}
	if (bytes.length < ENVELOPE_HEADER_LENGTH) {
		throw new Error('Envelope is truncated');
	}
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	const version = bytes[6];
	if (version !== ENVELOPE_VERSION) {
		throw new Error(`Unsupported envelope version ${version}`);
	}
	const urlLength = view.getUint16(12 + ENVELOPE_NONCE_LENGTH);
	if (urlLength > ENVELOPE_MAX_URL_LENGTH || bytes.length !== ENVELOPE_HEADER_LENGTH + urlLength) {
		throw new Error('Envelope length mismatch');
	}
	return {
		version,
		flags: bytes[7],
		exp: view.getUint32(8),
		nonce: bytes.slice(12, 12 + ENVELOPE_NONCE_LENGTH),
		url: utf8Decode(bytes.subarray(ENVELOPE_HEADER_LENGTH)),
	};
};

export const base64UrlEncode = (bytes: Uint8Array): string =>
	Buffer.from(bytes).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/[=]+$/, '');

export const base64UrlDecode = (value: string): Uint8Array => {
	const clean = value.replace(/\+/g, '-').replace(/\//g, '_').replace(/[=]+$/, '');
	if (!/^[A-Za-z0-9_-]*$/.test(clean) || clean.length % 4 === 1) {
		throw new Error('Invalid base64url');
	}
	return new Uint8Array(Buffer.from(clean.replace(/-/g, '+').replace(/_/g, '/'), 'base64'));
};
