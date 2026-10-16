import test from 'node:test';
import assert from 'node:assert/strict';
import Fastify from 'fastify';
import { installTrackMapFixtureControls } from './track-map-fixture';

test('native fixture counts only map requests and can fail and recover that endpoint', async () => {
	const app = Fastify();
	const snapshot = '/subwaysForNerds/api/v1/track-map/test-v1/snapshot';
	app.get(snapshot, () => ({ mapVersion: 'test-v1' }));
	app.get('/subwaysForNerds/api/v1/stations', () => []);
	installTrackMapFixtureControls(app);
	try {
		assert.deepEqual((await app.inject('/__test/track-map')).json(), { requests: 0, unavailable: false });
		assert.equal((await app.inject(snapshot)).statusCode, 200);
		assert.equal((await app.inject('/subwaysForNerds/api/v1/stations')).statusCode, 200);
		assert.deepEqual((await app.inject('/__test/track-map')).json(), { requests: 1, unavailable: false });
		await app.inject({ method: 'PUT', url: '/__test/track-map', payload: { unavailable: true } });
		assert.equal((await app.inject(snapshot)).statusCode, 503);
		assert.equal((await app.inject('/subwaysForNerds/api/v1/stations')).statusCode, 200);
		assert.deepEqual((await app.inject('/__test/track-map')).json(), { requests: 2, unavailable: true });
		await app.inject({ method: 'PUT', url: '/__test/track-map', payload: { unavailable: false, resetRequests: true } });
		assert.deepEqual((await app.inject('/__test/track-map')).json(), { requests: 0, unavailable: false });
		assert.equal((await app.inject(snapshot)).statusCode, 200);
		const invalid = await app.inject({ method: 'PUT', url: '/__test/track-map', payload: { unavailable: 'yes' } });
		assert.equal(invalid.statusCode, 400);
		assert.deepEqual((await app.inject('/__test/track-map')).json(), { requests: 1, unavailable: false });
	} finally { await app.close(); }
});
