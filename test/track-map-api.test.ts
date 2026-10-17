import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../server/index';
import { TransitService } from '../server/service';
import { validateTrackMapTopology } from '../server/track-map-data';
import type { TrackMapTopology } from '../shared/track-map';

const topology: TrackMapTopology = {
	schemaVersion: 1, mapVersion: 'test-v1', pdfSha256: 'a'.repeat(64),
	page: { width: 100, height: 100 }, attribution: 'Synthetic test geometry', sourceURL: 'https://example.invalid/map.pdf',
	stations: [{ id: 'L01', stationId: '630', partId: 'L01', name: '8 Av', point: { x: 10, y: 20 }, stopIds: ['L01N', 'L01S'] }],
	nodes: [{ id: 'platform', point: { x: 10, y: 20 } }], edges: [],
	platforms: [{ id: 'L01S-1', stopId: 'L01S', trackCodes: ['1'], nodeId: 'platform' }],
	coverage: { mappedStopIds: ['L01S'], unresolvedStopIds: ['L01N'], notes: [] },
};

test('invalid geometry and conflicting crosswalks fail before placement can use them', () => {
	const connected = structuredClone(topology);
	connected.nodes.push({ id: 'next', point: { x: 20, y: 20 } });
	connected.edges.push({ id: 'rail', from: 'platform', to: 'next', points: [{ x: 10, y: 20 }, { x: 20, y: 20 }], bidirectional: false, revenue: true });
	assert.equal(validateTrackMapTopology(connected), connected);
	const invalid: [string, (value: TrackMapTopology) => void][] = [
		['disconnected geometry', value => { value.edges[0].points[0] = { x: 11, y: 20 }; }],
		['zero-length rail', value => { value.nodes[1].point = { x: 10, y: 20 }; value.edges[0].points[1] = { x: 10, y: 20 }; }],
		['unknown platform stop', value => { value.platforms[0].stopId = 'missing'; }],
		['conflicting track crosswalk', value => { value.platforms.push({ ...value.platforms[0], id: 'duplicate', nodeId: 'next' }); }],
		['false mapped coverage', value => { value.coverage.mappedStopIds.push('L01N'); }],
		['overlapping coverage', value => { value.coverage.unresolvedStopIds.push('L01S'); }],
	];
	for (const [name, mutate] of invalid) {
		const value = structuredClone(connected);
		mutate(value);
		assert.throws(() => validateTrackMapTopology(value), name);
	}
});

test('track map snapshot uses cached feeds and rejects incompatible map versions', async () => {
	let fetched = 0;
	const service = new TransitService({ trackMapTopology: topology, fetcher: async () => { fetched++; throw new Error('Unexpected upstream request'); } });
	const app = await createServer(service);
	try {
		const response = await app.inject('/subwaysForNerds/api/v1/track-map/test-v1/snapshot');
		assert.equal(response.statusCode, 200);
		assert.equal(response.json().mapVersion, topology.mapVersion);
		assert.equal(response.json().pdfSha256, topology.pdfSha256);
		assert.deepEqual(response.json().trains, []);
		assert.ok(response.headers.etag);
		const mismatch = await app.inject('/subwaysForNerds/api/v1/track-map/other-v1/snapshot');
		assert.equal(mismatch.statusCode, 404);
		assert.equal(mismatch.json().error, 'Unsupported track map version');
		const health = (await app.inject('/subwaysForNerds/api/v1/health')).json();
		assert.equal(health.trackMap.available, true);
		assert.equal(health.slowZones.status, 'unavailable');
		assert.equal(fetched, 0);
	} finally { await app.close(); }
});

test('missing topology disables only the map and is visible in health', async () => {
	const service = new TransitService({ trackMapTopology: null });
	service.refreshBoards();
	const app = await createServer(service);
	try {
		const response = await app.inject('/subwaysForNerds/api/v1/track-map/nyc-2.6.8-v1/snapshot');
		assert.equal(response.statusCode, 503);
		const health = (await app.inject('/subwaysForNerds/api/v1/health')).json();
		assert.equal(health.trackMap.available, false);
		assert.equal(health.slowZones.status, 'unavailable');
		assert.equal((await app.inject('/subwaysForNerds/api/v1/stations/602/board')).statusCode, 200);
	} finally { await app.close(); }
});

test('bad topology cannot break departure service startup', async () => {
	const service = new TransitService({ trackMapTopology: { ...topology, page: { width: NaN, height: 100 } } });
	const app = await createServer(service);
	try {
		assert.equal((await app.inject('/subwaysForNerds/api/v1/track-map/test-v1/snapshot')).statusCode, 503);
		assert.equal((await app.inject('/subwaysForNerds/api/v1/stations')).statusCode, 200);
	} finally { await app.close(); }
});

test('a placement failure leaves departure boards usable and recovers on a later snapshot', async () => {
	const service = new TransitService({ trackMapTopology: topology });
	const snapshot = service.trackMap!.snapshot.bind(service.trackMap);
	service.trackMap!.snapshot = () => { throw new Error('Synthetic placement failure'); };
	assert.doesNotThrow(() => service.refreshBoards());
	const app = await createServer(service);
	try {
		assert.equal((await app.inject('/subwaysForNerds/api/v1/track-map/test-v1/snapshot')).statusCode, 503);
		assert.equal((await app.inject('/subwaysForNerds/api/v1/health')).json().trackMap.available, false);
		assert.equal((await app.inject('/subwaysForNerds/api/v1/stations/602/board')).statusCode, 200);
		service.trackMap!.snapshot = snapshot;
		assert.equal((await app.inject('/subwaysForNerds/api/v1/track-map/test-v1/snapshot')).statusCode, 200);
		assert.equal((await app.inject('/subwaysForNerds/api/v1/health')).json().trackMap.available, true);
	} finally { await app.close(); }
});
