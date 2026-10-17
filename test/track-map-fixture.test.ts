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

test('recorded slow-zone map overlay retains all three segment estimates on reviewed rails', async () => {
	const { createFixtureService, fixtureNow } = await import('./fixture-service');
	const originalNow = Date.now;
	Date.now = () => fixtureNow * 1000;
	let fixture: Awaited<ReturnType<typeof createFixtureService>> | undefined;
	try {
		fixture = await createFixtureService();
		const snapshot = fixture.service.mapSnapshot(fixtureNow);
		assert.ok(snapshot, 'The bundled map topology must load');
		const overlay = snapshot.slowZones;
		assert.ok(overlay, 'The map API must include slow-zone data');
		assert.equal(overlay.dataThrough, '2026-09-04');
		assert.ok(overlay.expiresAt! > fixtureNow);
		assert.equal(overlay.zones.length, 3);
		assert.equal(overlay.unmappedCount, 0);
		assert.deepEqual(overlay.zones.map(zone => [zone.from, zone.to]), [['633S', '634S'], ['419S', '420S'], ['L02N', 'L01N']]);
		for (const zone of overlay.zones) {
			assert.ok(zone.paths.length > 0, zone.segment);
			assert.ok(zone.paths.every(path => path.length >= 2 && path.every(point => Number.isFinite(point.x) && Number.isFinite(point.y))), zone.segment);
		}
	} finally {
		await fixture?.close();
		Date.now = originalNow;
	}
});
