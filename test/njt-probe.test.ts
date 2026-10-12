import test from 'node:test';
import assert from 'node:assert/strict';
import { probeNjt } from '../server/njt-probe';

test('missing or partial credentials makes no network requests', async () => {
	for (const credentials of [undefined, { username: 'u', password: '' }]) {
		const report = await probeNjt({ credentials, fetcher: async () => { throw Error('must not fetch'); } });
		assert.equal(report.access, 'missing-credentials');
		assert.equal(report.integrationReady, false);
	}
});

test('authenticates once and samples departures and positions independently for all modes', async () => {
	const requests: { url: string; form: FormData }[] = [];
	const report = await probeNjt({ credentials: { username: 'user-secret', password: 'password-secret' }, fetcher: async (url, init) => {
		requests.push({ url: String(url), form: init!.body as FormData });
		if (String(url).endsWith('authenticateUser')) return Response.json({ Authenticated: 'True', UserToken: 'token-secret' });
		if (String(url).endsWith('getBusDV')) return Response.json({ DVTrip: [{ departuretime: '11:05 PM', sched_dep_time: '11:05 PM', vehicle_id: 'EMPTY' }] });
		return Response.json([]);
	} });
	assert.equal(requests.length, 7);
	assert.equal(requests[0].form.get('password'), 'password-secret');
	assert.ok(requests.slice(1).every(r => r.form.get('token') === 'token-secret'));
	assert.deepEqual(requests.filter(r => r.url.endsWith('getVehicleLocations')).map(r => r.form.get('mode')), ['HBLR', 'NLR', 'RL']);
	assert.ok(report.samples.every(s => s.departures.status === 'unverified' && s.positions.status === 'empty'));
	assert.equal(report.integrationReady, false);
	assert.doesNotMatch(JSON.stringify(report), /user-secret|password-secret|token-secret/);
});

test('auth rejection does not retry or expose upstream error bodies', async () => {
	let calls = 0;
	const report = await probeNjt({ credentials: { username: 'u', password: 'p' }, fetcher: async () => {
		calls++;
		return new Response('secret upstream error', { status: 401 });
	} });
	assert.equal(calls, 1);
	assert.equal(report.access, 'failed');
	assert.doesNotMatch(JSON.stringify(report), /secret upstream/);
});

test('malformed auth response does not grant access', async () => {
	const report = await probeNjt({ credentials: { username: 'u', password: 'p' }, fetcher: async () => Response.json({ Authenticated: 'False', UserToken: 'secret' }) });
	assert.equal(report.access, 'failed');
	assert.equal(report.samples.length, 0);
});

test('position failure does not erase departure evidence and arbitrary fields never enter report', async () => {
	const report = await probeNjt({ credentials: { username: 'u', password: 'p' }, fetcher: async url => {
		if (String(url).endsWith('authenticateUser')) return Response.json({ Authenticated: 'True', UserToken: 'secret' });
		if (String(url).endsWith('getVehicleLocations')) throw Error('secret request token');
		return Response.json({ DVTrip: [{ token: 'secret', vehicle_id: '123' }] });
	} });
	assert.ok(report.samples.every(s => s.departures.status === 'unverified' && s.positions.status === 'failed'));
	assert.doesNotMatch(JSON.stringify(report), /secret/);
});

test('unexpected response shapes are failed rather than empty coverage', async () => {
	const report = await probeNjt({ credentials: { username: 'u', password: 'p' }, fetcher: async url => Response.json(String(url).endsWith('authenticateUser') ? { Authenticated: 'True', UserToken: 't' } : { message: 'Access denied' }) });
	assert.ok(report.samples.every(s => s.departures.status === 'failed' && s.positions.status === 'failed'));
});
