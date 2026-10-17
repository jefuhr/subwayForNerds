import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { TrackMapSnapshot, TrackMapTopology } from '../shared/track-map';
import { TrackMapPlacement } from '../server/track-map';
import { SlowZoneService, type SlowZoneRow } from '../server/slow-zones';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';

const now = Date.parse('2026-10-16T14:00:00Z') / 1000;
const topology = (): TrackMapTopology => {
	const value = JSON.parse(readFileSync(new URL('fixtures/track-map-placement/topology.json', import.meta.url), 'utf8'));
	value.pdfSha256 = 'a'.repeat(64);
	// One reviewed directional platform pair for the synthetic curved segment.
	value.platforms = value.platforms.filter((p: { id: string }) => !['a2', 'b2'].includes(p.id));
	return value;
};
const row = (patch: Partial<SlowZoneRow> = {}): SlowZoneRow => ({ a_stop: 'AN', b_stop: 'BN', segment: 'Alpha → Beta', routes: '1 2',
	start_date: '2026-09-01', end_date: '2026-10-15', slow_days: 30, baseline_s: 100, extra_s_median: 50, kind: 'slow zone', ...patch });
const zones = (rows = [row()]) => { const value = new SlowZoneService(); value.accept(rows, { fetchedAt: now }); return value; };
const snapshot = (data?: SlowZoneService, map = topology(), time = now) => new TrackMapPlacement(map).snapshot([], [], time, undefined, data);

test('missing slow-zone data is an empty optional-compatible snapshot', () => {
	assert.deepEqual(snapshot().slowZones, { dataThrough: null, expiresAt: null, zones: [], unmappedCount: 0 });
	const legacy: TrackMapSnapshot = { schemaVersion: 1, mapVersion: 'legacy', pdfSha256: '', generatedAt: now, sources: [], trains: [],
		coverage: { placed: 0, uncertain: 0, unplaced: 0 } };
	assert.equal(legacy.slowZones, undefined);
	assert.deepEqual(snapshot(new SlowZoneService()).slowZones, snapshot().slowZones);
});

test('all active dataset segments project without trains and preserve reviewed polyline bends and estimates', () => {
	const data = zones([row(), row({ a_stop: 'BN', b_stop: 'CN', routes: '', kind: 'disruption', extra_s_median: 150 })]);
	const value = snapshot(data);
	assert.deepEqual(value.trains, []);
	assert.equal(value.slowZones!.zones.length, 2);
	assert.equal(value.slowZones!.unmappedCount, 0);
	const first = value.slowZones!.zones[0];
	assert.deepEqual(first.paths, [[{ x: 0, y: 0 }, { x: 30, y: 0 }, { x: 30, y: 40 }]]);
	assert.deepEqual(first.routes, ['1', '2']);
	assert.equal(first.extraSeconds, 50);
	assert.equal(first.segment, 'Alpha → Beta');
	assert.ok(first.id);
	assert.deepEqual(value.slowZones!.zones[1].routes, []);
	assert.equal(value.slowZones!.zones[1].kind, 'disruption');
	assert.equal(snapshot(data).slowZones!.zones[0].id, first.id);
	assert.equal(value.slowZones!.dataThrough, '2026-10-15');
});

test('directed, missing, nonrevenue, broken and ambiguous geometry remains explicitly unmapped', () => {
	const cases: [string, (map: TrackMapTopology) => void, Partial<SlowZoneRow>?][] = [
		['reverse', () => {}, { a_stop: 'BN', b_stop: 'AN' }],
		['direction is exact', () => {}, { a_stop: 'AS' }],
		['missing', map => { map.edges = []; }],
		['nonrevenue', map => { map.edges[0].revenue = false; }],
		['missing polyline', map => { map.edges[0].points = []; }],
		['broken endpoint', map => { map.edges[0].points[0] = { x: 1, y: 1 }; }],
		['parallel paths', map => { map.edges.push({ ...map.edges[0], id: 'alternative' }); }],
		['different length paths', map => { map.edges.push({ ...map.edges[0], id: 'shorter', points: [map.nodes[0].point, map.nodes[2].point] }); }],
		['multiple platforms', map => { map.platforms.push({ id: 'a2', stopId: 'AN', trackCodes: ['2'], nodeId: 'a2' }, { id: 'b2', stopId: 'BN', trackCodes: ['4'], nodeId: 'b2' }); }],
	];
	for (const [name, mutate, patch] of cases) {
		const map = topology(); mutate(map);
		const value = snapshot(zones([row(patch)]), map).slowZones!;
		assert.equal(value.zones.length, 1, name);
		assert.deepEqual(value.zones[0].paths, [], name);
		assert.equal(value.unmappedCount, 1, name);
	}
});

test('14-day Eastern date freshness expires exactly at the first ineligible midnight including DST', () => {
	for (const [through, expiry] of [
		['2026-10-15', '2026-10-30T04:00:00Z'],
		['2026-10-20', '2026-11-04T05:00:00Z'],
		['2026-02-25', '2026-03-12T04:00:00Z'],
	]) {
		const data = zones([row({ end_date: through })]);
		const deadline = Date.parse(expiry) / 1000;
		assert.equal(snapshot(data, topology(), deadline - 1).slowZones!.expiresAt, deadline);
		assert.equal(snapshot(data, topology(), deadline - 1).slowZones!.zones.length, 1);
		for (const time of [deadline, deadline + 1]) {
			const value = snapshot(data, topology(), time).slowZones!;
			assert.equal(data.live(time), false);
			assert.deepEqual(value, { dataThrough: through, expiresAt: deadline, zones: [], unmappedCount: 0 });
		}
	}
});


test('an unavailable expiry cannot expose active map estimates', () => {
	for (const deadline of [null, NaN, Infinity]) {
		const data = zones(); data.expiresAt = deadline;
		assert.deepEqual(snapshot(data).slowZones!.zones, []);
		assert.equal(snapshot(data).slowZones!.unmappedCount, 0);
	}
});

test('restored snapshots preserve original dataset deadline even after a successful fetch or source error', () => {
	const data = zones();
	const restored = new SlowZoneService(); restored.restore(data.snapshot());
	restored.state = { ...restored.state, fetchedAt: now + 86400, error: 'offline' };
	assert.deepEqual(snapshot(restored).slowZones, snapshot(data).slowZones);
	assert.equal(restored.health(now).status, 'degraded');
});

test('same-second dataset acceptance and restoration invalidate the service map cache independently of boards', () => {
	const service = new TransitService({ trackMapTopology: topology() });
	const empty = service.mapSnapshot(now)!;
	service.slowZones.accept([row()], { fetchedAt: now });
	const first = service.mapSnapshot(now)!;
	assert.notEqual(first, empty);
	assert.equal(first.slowZones!.zones[0].extraSeconds, 50);
	assert.equal(service.mapSnapshot(now), first);
	service.slowZones.accept([row({ extra_s_median: 75 })], { fetchedAt: now });
	const second = service.mapSnapshot(now)!;
	assert.notEqual(second, first);
	assert.equal(second.slowZones!.zones[0].extraSeconds, 75);
	service.slowZones.restore(zones([row({ extra_s_median: 80 })]).snapshot());
	assert.equal(service.mapSnapshot(now)!.slowZones!.zones[0].extraSeconds, 80);
});

test('map and slow-zone health coexist with usable boards and unavailable train feeds', async t => {
	t.mock.method(Date, 'now', () => now * 1000);
	const service = new TransitService({ trackMapTopology: topology() });
	service.slowZones.accept([row()], { fetchedAt: now });
	service.refreshBoards(now);
	const app = await createServer(service);
	try {
		const health = (await app.inject('/subwaysForNerds/api/v1/health')).json();
		assert.equal(health.trackMap.available, true);
		assert.equal(health.slowZones.dataThrough, '2026-10-15');
		assert.equal(health.slowZones.active, 1);
		assert.equal((await app.inject('/subwaysForNerds/api/v1/stations/602/board')).statusCode, 200);
		assert.equal(service.mapSnapshot(now)!.slowZones!.zones.length, 1);
		const url = `/subwaysForNerds/api/v1/track-map/${service.trackMapVersion}/snapshot`;
		const first = await app.inject(url);
		assert.equal(first.statusCode, 200);
		assert.equal(first.json().slowZones.zones[0].extraSeconds, 50);
		service.slowZones.accept([row({ extra_s_median: 75 })], { fetchedAt: now });
		const changed = await app.inject({ url, headers: { 'if-none-match': first.headers.etag! } });
		assert.equal(changed.statusCode, 200, 'same-second slow-zone change must not receive 304');
		assert.notEqual(changed.headers.etag, first.headers.etag);
		assert.equal(changed.json().slowZones.zones[0].extraSeconds, 75);
	} finally { await app.close(); }
});
