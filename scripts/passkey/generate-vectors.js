#!/usr/bin/env node
/**
 * Regenerates __tests__/fixtures/passkey/vectors.json.
 * Usage: node scripts/passkey/generate-vectors.js
 */
const { Buffer } = require('buffer');
const fs = require('fs');
const path = require('path');
const ref = require('./protocol-reference');

const hex = bytes => Buffer.from(bytes).toString('hex');
const fill = (length, start) => Buffer.from(Array.from({ length }, (_, i) => (start + i) % 256));

const RP_ID = 'pubky-ring-demo.vercel.app';
const PUBKY = 'o1gg96ewuojmopcjbz8895478wdtxtzzuxnfjjz8o8e77csa1ngo';
const URL =
	'pubkyauth://signin_grant?caps=%2Fpub%2Fpubky.app%2F%3Arw&relay=https%3A%2F%2Fhttprelay.staging.pubky.app%2Finbox' +
	`&cid=${RP_ID}&cpk=8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo&af=v1` +
	'&epk=kgq7x5r3cqh8sdi4bopp7xa1kbtxwkmbh8xbxfndy5b9f9wq3g3o';

const envelopeInput = { version: 1, flags: 0, exp: 1893456000, nonce: fill(16, 0x10), url: URL };
const envelope = ref.encodeEnvelope(envelopeInput);

const r = fill(32, 0xa0);
const s = ref.prfSalt(r);
const gcmNonce = fill(12, 0x40);
const body = ref.sealMailbox({ s, gcmNonce, envelope, rpId: RP_ID });

const vectors = {
	description:
		'Pubky WebAuthn envelope and iOS PRF mailbox vectors. Regenerate with node scripts/passkey/generate-vectors.js.',
	envelope: {
		input: { ...envelopeInput, nonce: hex(envelopeInput.nonce) },
		hex: hex(envelope),
		base64url: envelope.toString('base64url'),
	},
	mailbox: {
		rpId: RP_ID,
		prfInputHex: hex(r),
		prfSaltHex: hex(s),
		keyHex: hex(ref.mailboxKey(s)),
		channel: ref.mailboxChannel(s),
		gcmNonceHex: hex(gcmNonce),
		bodyHex: hex(body),
	},
	credentialId: {
		rpId: RP_ID,
		pubky: PUBKY,
		hex: hex(ref.credentialId(RP_ID, PUBKY)),
	},
};

const out = path.join(__dirname, '../../__tests__/fixtures/passkey/vectors.json');
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, `${JSON.stringify(vectors, null, '\t')}\n`);
console.log(`Wrote ${out}`);
