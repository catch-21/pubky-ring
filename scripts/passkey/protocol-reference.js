/**
 * Node reference implementation of the Pubky WebAuthn envelope and the iOS
 * PRF request mailbox (PLAN.md sections 5.3 and 6.2). It exists only to
 * produce and check the shared vectors in
 * __tests__/fixtures/passkey/vectors.json, which the Swift extension and the
 * pubky-app web implementation are tested against.
 */
const { Buffer } = require('buffer');
const crypto = require('crypto');

const MAILBOX_DOMAIN = 'pubky-ring-webauthn-mailbox-v1';

const encodeEnvelope = ({ version = 1, flags = 0, exp, nonce, url }) => {
	const urlBytes = Buffer.from(url, 'utf8');
	const header = Buffer.alloc(30);
	header.write('PKYWA1', 0, 'ascii');
	header[6] = version;
	header[7] = flags;
	header.writeUInt32BE(exp, 8);
	Buffer.from(nonce).copy(header, 12);
	header.writeUInt16BE(urlBytes.length, 28);
	return Buffer.concat([header, urlBytes]);
};

const sha256 = (...parts) => crypto.createHash('sha256').update(Buffer.concat(parts.map(part => Buffer.from(part)))).digest();

/** WebAuthn PRF salt hashing: what an authenticator receives for prf.eval.first = r. */
const prfSalt = r => sha256(Buffer.from('WebAuthn PRF', 'utf8'), Buffer.from([0]), r);

const mailboxKey = s => Buffer.from(crypto.hkdfSync('sha256', s, Buffer.alloc(0), Buffer.from(`${MAILBOX_DOMAIN}/key`, 'utf8'), 32));

const mailboxChannel = s => sha256(Buffer.from(`${MAILBOX_DOMAIN}/channel`, 'utf8'), s).toString('base64url');

const sealMailbox = ({ s, gcmNonce, envelope, rpId }) => {
	const cipher = crypto.createCipheriv('aes-256-gcm', mailboxKey(s), gcmNonce);
	cipher.setAAD(Buffer.from(rpId, 'utf8'));
	const ciphertext = Buffer.concat([cipher.update(envelope), cipher.final()]);
	return Buffer.concat([gcmNonce, ciphertext, cipher.getAuthTag()]);
};

const openMailbox = ({ s, body, rpId }) => {
	const decipher = crypto.createDecipheriv('aes-256-gcm', mailboxKey(s), body.subarray(0, 12));
	decipher.setAAD(Buffer.from(rpId, 'utf8'));
	decipher.setAuthTag(body.subarray(body.length - 16));
	return Buffer.concat([decipher.update(body.subarray(12, body.length - 16)), decipher.final()]);
};

/** Ring credential ID for (rpId, pubky): 16 bytes, stable across reinstalls of the snapshot. */
const credentialId = (rpId, pubky) => sha256(Buffer.from('pubky-ring-credential-v1', 'utf8'), Buffer.from([0]), Buffer.from(rpId, 'utf8'), Buffer.from([0]), Buffer.from(pubky, 'utf8')).subarray(0, 16);

module.exports = {
	MAILBOX_DOMAIN,
	encodeEnvelope,
	prfSalt,
	mailboxKey,
	mailboxChannel,
	sealMailbox,
	openMailbox,
	credentialId,
};
