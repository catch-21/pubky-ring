import vectors from './fixtures/passkey/vectors.json';
import { base64UrlEncode, encodeEnvelope } from '../src/passkey/envelope';
import {
	postRefusalReport,
	refusePasskeyRequest,
	reportBody,
	reportChannel,
	reportUrlFor,
} from '../src/passkey/report';
import { cancelPasskeyRequest } from '../src/passkey/native';

jest.mock('../src/passkey/native', () => ({ cancelPasskeyRequest: jest.fn(async () => true) }));

const reference = require('../scripts/passkey/protocol-reference');

const nonce = new Uint8Array(Buffer.from(vectors.report.nonceHex, 'hex'));
const envelopeWith = (relay: string): string =>
	base64UrlEncode(
		encodeEnvelope({
			exp: vectors.envelope.input.exp,
			nonce,
			url: `pubkyauth://signin_grant?relay=${encodeURIComponent(relay)}&cid=pubky.app`,
		}),
	);

const okFetch = (): jest.Mock => jest.fn(async () => ({ ok: true }) as Response);

describe('passkey refusal report', () => {
	it('derives the documented channel, URL and body', () => {
		expect(reportChannel(nonce)).toBe(vectors.report.channel);
		expect(reference.reportChannel(Buffer.from(nonce))).toBe(vectors.report.channel);
		expect(reportUrlFor(envelopeWith(vectors.report.relay))).toBe(vectors.report.url);
		expect(reportBody(vectors.report.reason as 'client_id_mismatch')).toBe(vectors.report.body);
		expect(reportUrlFor(vectors.envelope.base64url)).toBe(
			`https://httprelay.staging.pubky.app/inbox/${vectors.report.channel}`,
		);
	});

	it('reports only to an https relay of a readable envelope', () => {
		expect(reportUrlFor(envelopeWith('http://relay.example/inbox'))).toBeNull();
		expect(reportUrlFor(envelopeWith('https://relay.example/inbox?x=1'))).toBeNull();
		expect(reportUrlFor('not-an-envelope')).toBeNull();
		expect(reportUrlFor('!')).toBeNull();
	});

	it('posts the reason and then ends the request as a refusal', async () => {
		const fetchImpl = okFetch();
		await refusePasskeyRequest({
			requestId: 'request-1',
			envelope: vectors.envelope.base64url,
			reason: 'client_id_mismatch',
			fetchImpl,
		});
		expect(fetchImpl).toHaveBeenCalledWith(
			`https://httprelay.staging.pubky.app/inbox/${vectors.report.channel}`,
			expect.objectContaining({ method: 'POST', body: vectors.report.body }),
		);
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-1', 'client_id_mismatch', { refused: true });
		expect(fetchImpl.mock.invocationCallOrder[0]).toBeLessThan(
			jest.mocked(cancelPasskeyRequest).mock.invocationCallOrder[0],
		);
	});

	it('still refuses when there is nowhere to report or the relay fails', async () => {
		const fetchImpl = jest.fn(async () => {
			throw new Error('offline');
		});
		await refusePasskeyRequest({ requestId: 'request-2', envelope: '!', reason: 'malformed', fetchImpl });
		expect(fetchImpl).not.toHaveBeenCalled();
		await refusePasskeyRequest({
			requestId: 'request-3',
			envelope: vectors.envelope.base64url,
			reason: 'expired',
			fetchImpl,
		});
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-2', 'malformed', { refused: true });
		expect(cancelPasskeyRequest).toHaveBeenCalledWith('request-3', 'expired', { refused: true });
	});

	it('gives up on a slow relay', async () => {
		jest.useFakeTimers();
		const fetchImpl = jest.fn(
			(_url: RequestInfo | URL, init?: RequestInit) =>
				new Promise<Response>((_resolve, reject) => {
					init?.signal?.addEventListener('abort', () => reject(new Error('aborted')));
				}),
		);
		const posted = postRefusalReport(vectors.report.url, 'expired', { fetchImpl, timeoutMs: 3000 });
		jest.advanceTimersByTime(3000);
		await expect(posted).resolves.toBe(false);
		jest.useRealTimers();
	});
});
