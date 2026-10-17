import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { activeSlowZones, decodeSlowZones, SlowZoneService, SLOW_ZONES_URL, type SlowZoneRow } from '../server/slow-zones';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';
import { createFixtureService, fixtureNow } from './fixture-service';
import { slowZoneSummary } from '../shared/slow-zones';
import type { Train } from '../shared/types';

const parquet = readFileSync(new URL('fixtures/subway_slow_zones.parquet', import.meta.url));
// Friday 2026-10-16 10:00 Eastern; the recorded dataset runs through Thursday.
const now = Date.parse('2026-10-16T14:00:00Z') / 1000;
const row = (a: string, b: string, patch: Partial<SlowZoneRow> = {}): SlowZoneRow => ({ a_stop: a, b_stop: b, segment: `${a} → ${b}`, routes: 'N W',
	start_date: '2026-09-01', end_date: '2026-10-15', slow_days: 30, baseline_s: 95.2, extra_s_median: 50, kind: 'slow zone', ...patch });
const train = (stops: string[], position?: Train['position'], patch: Partial<Train> = {}): Train => ({ key: 'gtfs-nqrw|20261016|060000_N..S|', feed: 'gtfs-nqrw',
	tripId: '060000_N..S', serviceDate: '20261016', route: 'N', destination: 'Coney Island', direction: 'SOUTH', timestamp: now, alerts: [],
	stops: stops.map((id, i) => ({ id: id.replace(/!$/, ''), name: id, arrival: now + i * 120, departure: null, ...(id.endsWith('!') ? { relationship: 'SKIPPED' } : {}) })),
	...(position ? { position } : {}), ...patch });
const service = (rows: SlowZoneRow[]) => { const s = new SlowZoneService(); s.accept(rows, { fetchedAt: now, timestamp: now - 3600 }); return s; };
const stripped = (t: Train) => t.slowZones?.map(z => ({ from: z.from, to: z.to, toIndex: z.toIndex, current: !!z.current }));

test('decodes the recorded Transit Lab parquet snapshot into plain numbers and dates', async () => {
	const rows = await decodeSlowZones(parquet);
	assert.equal(rows.length, 10542);
	assert.deepEqual(rows[0], { a_stop: 'B06S', b_stop: 'B08S', segment: 'Roosevelt Island → Lexington Av/63 St', routes: 'F FX',
		start_date: '2024-02-06', end_date: '2024-08-28', slow_days: 146, baseline_s: 29.2, extra_s_median: 82, kind: 'service change' });
	assert.deepEqual(new Set(rows.map(r => r.kind)), new Set(['slow zone', 'disruption', 'service change', 'system-wide change']));
	assert.ok(rows.every(r => /^[0-9A-Z]+[NS]$/.test(r.a_stop) && /^[0-9A-Z]+[NS]$/.test(r.b_stop)));
});

test('the active window reproduces Transit Lab\'s published count', async () => {
	const { dataThrough, zones } = activeSlowZones(await decodeSlowZones(parquet));
	assert.equal(dataThrough, '2026-10-15');
	// transitlab.nyc/slow-zones reported 88 active slow zones on 2026-10-16; one disruption is also active.
	assert.equal(zones.filter(z => z.kind === 'slow').length, 88);
	assert.equal(zones.filter(z => z.kind === 'disruption').length, 1);
	const queensboro = zones.find(z => z.from === 'R09S' && z.to === 'R60S')!;
	assert.deepEqual(slowZoneSummary(queensboro), { from: 'R09S', to: 'R60S', segment: 'Queensboro Plaza → 60 St tunnel', kind: 'slow',
		since: '2026-06-08', through: '2026-10-15', extraSeconds: 50, baselineSeconds: 95.2, slowDays: 92 });
});

test('active zones keep slow zones and disruptions within seven days of the latest data', () => {
	const { dataThrough, zones } = activeSlowZones([
		row('A1S', 'A2S', { end_date: '2026-10-08' }), // exactly seven days before
		row('A2S', 'A3S', { end_date: '2026-10-07' }), // eight days before
		row('A3S', 'A4S', { kind: 'disruption', extra_s_median: 134.4 }),
		row('A4S', 'A5S', { kind: 'service change' }),
		row('A5S', 'A6S', { kind: 'system-wide change' }),
		row('A6S', 'A7S', { start_date: '2026-10-01', end_date: '2026-10-09', extra_s_median: 10 }),
		row('A6S', 'A7S', { start_date: '2026-10-12', end_date: '2026-10-14', extra_s_median: 20 }),
	]);
	assert.equal(dataThrough, '2026-10-15');
	assert.deepEqual(zones.map(z => [z.from, z.kind, z.extraSeconds]), [['A1S', 'slow', 50], ['A3S', 'disruption', 134.4], ['A6S', 'slow', 20]]);
});

test('zones ahead follow served stops, bridge skips and timing points, and ignore the route', () => {
	const zones = service([row('R09S', 'R60S'), row('R60S', 'R11S', { routes: 'N W' }), row('R13S', 'R15S'), row('R14S', 'R15S', { routes: 'Q' })]);
	const t = train(['R08S', 'R09S', 'R60S', 'R11S', 'R13S', 'R14S!', 'R15S'], { stopId: 'R08S', name: '39 Av', status: 'STOPPED_AT' }, { route: 'R' });
	zones.enrich(t, now);
	assert.deepEqual(stripped(t), [
		{ from: 'R09S', to: 'R60S', toIndex: 2, current: false },
		{ from: 'R60S', to: 'R11S', toIndex: 3, current: false },
		{ from: 'R13S', to: 'R15S', toIndex: 6, current: false },
	]);
});

test('segments behind the reported position are not ahead', () => {
	const zones = service([row('D27N', 'D26N'), row('D26N', 'D25N')]);
	const t = train(['D27N', 'D26N', 'D25N'], { stopId: 'D26N', name: 'Prospect Park', status: 'STOPPED_AT' });
	zones.enrich(t, now);
	assert.deepEqual(stripped(t), [{ from: 'D26N', to: 'D25N', toIndex: 2, current: false }]);
});

test('a train is currently in a zone only while moving toward the segment end after its observed previous stop', () => {
	const zones = service([row('R09S', 'R60S'), row('G21S', 'R60S', { routes: 'R' })]);
	const at = train(['R09S', 'R60S', 'R11S'], { stopId: 'R09S', name: 'Queensboro Plaza', status: 'STOPPED_AT' });
	zones.enrich(at, now);
	assert.deepEqual(stripped(at), [{ from: 'R09S', to: 'R60S', toIndex: 1, current: false }]);
	const moving = train(['R60S', 'R11S'], { stopId: 'R60S', name: 'R60S', status: 'IN_TRANSIT_TO' });
	zones.enrich(moving, now + 15);
	assert.deepEqual(stripped(moving), [{ from: 'R09S', to: 'R60S', toIndex: 0, current: true }]);
	assert.deepEqual(slowZoneSummary(moving.slowZones!.find(z => z.current)!).segment, 'R09S → R60S');
	const arrived = train(['R60S', 'R11S'], { stopId: 'R60S', name: 'R60S', status: 'STOPPED_AT' });
	zones.enrich(arrived, now + 30);
	assert.equal(arrived.slowZones, undefined);
});

test('a missing status counts as moving only when the report is fresh and the next predicted arrival is ahead', () => {
	const zones = service([row('R09S', 'R60S')]);
	zones.enrich(train(['R09S', 'R60S'], { stopId: 'R09S', name: 'Queensboro Plaza', status: 'STOPPED_AT' }), now);
	const moving = (position: Partial<NonNullable<Train['position']>>, arrival: number | null, stops = ['R60S', 'R11S']) => {
		const t = train(stops, { stopId: 'R60S', name: 'R60S', ...position });
		t.stops[0].arrival = arrival;
		zones.enrich(t, now + 15);
		return !!t.slowZones?.some(z => z.current);
	};
	assert.equal(moving({ timestamp: now - 10 }, now + 60), true);
	assert.equal(moving({}, now + 60), false, 'no report time');
	// Trips that have not left their terminal report a future placeholder time.
	assert.equal(moving({ timestamp: now + 600 }, now + 60), false, 'future report');
	assert.equal(moving({ timestamp: now - 10 }, now - 5), false, 'arrival already passed');
	assert.equal(moving({ timestamp: now - 10 }, null), false, 'no arrival prediction');
	assert.equal(moving({ timestamp: now - 10 }, now + 60, ['R11S', 'R60S']), false, 'reported stop is not next');
	assert.equal(moving({ timestamp: now - 10, status: 'INCOMING_AT' }, null), true, 'explicit status needs no inference');
});

test('without observed history, the feed\'s own earlier stop or the matched schedule supplies the previous stop', () => {
	const zones = service([row('R09S', 'R60S'), row('G21S', 'R60S', { routes: 'R' }), row('R20S', 'R21S'), row('Q01S', 'R21S', { routes: 'Q' })]);
	const reported = train(['R09S', 'R60S', 'R11S'], { stopId: 'R60S', name: 'R60S', status: 'IN_TRANSIT_TO' });
	zones.enrich(reported, now);
	assert.deepEqual(stripped(reported), [{ from: 'R09S', to: 'R60S', toIndex: 1, current: true }]);
	const scheduled = train(['R21S', 'R22S'], { stopId: 'R21S', name: '8 St-NYU', status: 'IN_TRANSIT_TO' },
		{ key: 'other', scheduledPattern: { shape: 'N..S', headsign: 'Coney Island', stops: ['R17S', 'R20S', 'R21S', 'R22S'], source: 'gtfs_subway' } });
	zones.enrich(scheduled, now);
	assert.deepEqual(stripped(scheduled), [{ from: 'R20S', to: 'R21S', toIndex: 0, current: true }]);
});

test('a unique end stop is accepted only for a route measured on that segment, and ambiguity shows nothing', () => {
	const zones = service([row('R09S', 'R60S', { routes: 'N W' }), row('L02N', 'L01N', { routes: 'L' }), row('G21S', 'R11S', { routes: 'R W' }), row('R60S', 'R11S', { routes: 'N W' })]);
	const n = train(['R60S', 'R11S'], { stopId: 'R60S', name: 'R60S', status: 'IN_TRANSIT_TO' }, { key: 'n' });
	zones.enrich(n, now);
	assert.equal(n.slowZones?.[0].current, true);
	const r = train(['R60S', 'R11S'], { stopId: 'R60S', name: 'R60S', status: 'IN_TRANSIT_TO' }, { key: 'r', route: 'R' });
	zones.enrich(r, now);
	assert.equal(r.slowZones?.some(z => z.current), false);
	assert.deepEqual(stripped(r), [{ from: 'R60S', to: 'R11S', toIndex: 1, current: false }]);
	const ambiguous = train(['R11S', 'R13S'], { stopId: 'R11S', name: 'Lexington Av/59 St', status: 'IN_TRANSIT_TO' }, { key: 'ambiguous', route: 'W' });
	zones.enrich(ambiguous, now);
	assert.equal(ambiguous.slowZones, undefined);
});

test('history ignores backward reports and expires after fifteen minutes', () => {
	const zones = service([row('R09S', 'R60S'), row('R60S', 'R11S'), row('G21S', 'R11S', { routes: 'N R' })]);
	zones.enrich(train(['R11S', 'R13S'], { stopId: 'R11S', name: 'Lexington Av/59 St', status: 'STOPPED_AT' }), now);
	// A glitch reporting an earlier stop must not make the stop ahead its predecessor.
	const back = train(['R60S', 'R11S'], { stopId: 'R60S', name: 'R60S', status: 'IN_TRANSIT_TO' });
	zones.enrich(back, now + 15);
	assert.equal(back.slowZones?.find(z => z.current)?.from, 'R09S');
	zones.enrich(train(['R60S', 'R11S'], { stopId: 'R60S', name: 'R60S', status: 'STOPPED_AT' }), now + 30);
	const later = train(['R11S', 'R13S'], { stopId: 'R11S', name: 'Lexington Av/59 St', status: 'IN_TRANSIT_TO' });
	zones.enrich(later, now + 45);
	assert.equal(later.slowZones?.find(z => z.current)?.from, 'R60S');
	zones.prune(now + 45 + 901);
	const expired = train(['R11S', 'R13S'], { stopId: 'R11S', name: 'Lexington Av/59 St', status: 'IN_TRANSIT_TO' });
	zones.enrich(expired, now + 45 + 902);
	assert.equal(expired.slowZones, undefined);
});

test('stale datasets and non-subway trains carry no zones', () => {
	const zones = service([row('R09S', 'R60S')]);
	const fresh = train(['R09S', 'R60S']);
	zones.enrich(fresh, Date.parse('2026-10-29T14:00:00Z') / 1000);
	assert.equal(fresh.slowZones?.length, 1);
	const stale = train(['R09S', 'R60S']);
	zones.enrich(stale, Date.parse('2026-10-30T14:00:00Z') / 1000);
	assert.equal(stale.slowZones, undefined);
	assert.equal(zones.health(Date.parse('2026-10-30T14:00:00Z') / 1000).status, 'degraded');
	const path = train(['R09S', 'R60S'], undefined, { feed: 'path' });
	zones.enrich(path, now);
	assert.equal(path.slowZones, undefined);
});

test('the poller sends its ETag, keeps the last good dataset on failure, and restores it after restart', async t => {
	const directory = await mkdtemp(join(tmpdir(), 'sfn-slow-zones-'));
	t.after(() => rm(directory, { recursive: true, force: true }));
	const requests: { url: string; etag: string | null }[] = [];
	let respond = () => new Response(parquet, { headers: { etag: '"one"', 'last-modified': 'Fri, 16 Oct 2026 06:52:11 GMT' } });
	const fetcher = (async (url: string, init?: RequestInit) => {
		requests.push({ url, etag: new Headers(init?.headers).get('if-none-match') }); return respond();
	}) as typeof fetch;
	t.mock.method(Date, 'now', () => now * 1000);
	const first = new TransitService({ cacheDir: directory, fetcher });
	await first.refreshSlowZones();
	assert.equal(first.slowZones.zones.length, 89);
	assert.deepEqual(first.slowZones.state, { id: 'slow-zones', timestamp: Date.parse('2026-10-16T06:52:11Z') / 1000, fetchedAt: now, error: null });
	respond = () => new Response(null, { status: 304 });
	await first.refreshSlowZones();
	respond = () => new Response('nope', { status: 503 });
	await assert.rejects(first.refreshSlowZones(), /HTTP 503/);
	respond = () => new Response(new Uint8Array([1, 2, 3]));
	await assert.rejects(first.refreshSlowZones());
	assert.equal(first.slowZones.zones.length, 89);
	assert.match(first.slowZones.state.error!, /./);
	assert.deepEqual(requests.map(r => [r.url, r.etag]), [[SLOW_ZONES_URL, null], [SLOW_ZONES_URL, '"one"'], [SLOW_ZONES_URL, '"one"'], [SLOW_ZONES_URL, '"one"']]);
	await first.stop();

	respond = () => { throw new Error('offline'); };
	const restarted = new TransitService({ cacheDir: directory, fetcher });
	await assert.rejects(restarted.refreshSlowZones(), /offline/);
	assert.equal(restarted.slowZones.zones.length, 89);
	assert.equal(restarted.slowZones.dataThrough, '2026-10-15');
	assert.equal(restarted.slowZones.etag, '"one"');
	await restarted.stop();
});

test('an incomplete dataset is rejected instead of clearing every zone', async t => {
	t.mock.method(Date, 'now', () => now * 1000);
	const directory = await mkdtemp(join(tmpdir(), 'sfn-slow-zones-'));
	t.after(() => rm(directory, { recursive: true, force: true }));
	const s = new TransitService({ cacheDir: directory, fetcher: (async () => new Response(parquet)) as typeof fetch });
	await s.refreshSlowZones();
	assert.throws(() => s.slowZones.accept([row('R09S', 'R60S')], { fetchedAt: now, minimumRows: 1000 }), /Incomplete slow zone dataset/);
	assert.equal(s.slowZones.zones.length, 89);
	await s.stop();
});

test('board rows carry only the current zone and train details carry every zone ahead', async t => {
	const originalNow = Date.now;
	Date.now = () => fixtureNow * 1000;
	t.after(() => { Date.now = originalNow; });
	const fixture = await createFixtureService();
	t.after(() => fixture.close());
	const app = await createServer(fixture.service);
	t.after(() => app.close());
	const board = (await app.inject('/subwaysForNerds/api/v1/stations/602/board')).json();
	const tagged = board.departures.filter((d: any) => d.slowZone);
	assert.ok(tagged.length >= 1);
	assert.ok(tagged.every((d: any) => d.route === '4' && d.slowZone.from === '633S' && d.slowZone.to === '634S' && !('toIndex' in d.slowZone) && !('current' in d.slowZone)));
	const trip = (await app.inject('/subwaysForNerds/api/v1/trips?' + new URLSearchParams({ key: tagged[0].tripKey }))).json();
	assert.deepEqual(trip.train.slowZones.map((z: any) => [z.from, z.to, z.toIndex, !!z.current, z.kind]), [['633S', '634S', 0, true, 'slow'], ['419S', '420S', 9, false, 'disruption']]);
	const selected = (await app.inject('/subwaysForNerds/api/v1/trips?' + new URLSearchParams({ key: fixture.selectedTripKey }))).json();
	assert.deepEqual(selected.train.slowZones.map((z: any) => [z.from, z.to, z.toIndex, !!z.current]), [['L02N', 'L01N', 2, false]]);
	const health = (await app.inject('/subwaysForNerds/api/v1/health')).json();
	assert.deepEqual(health.slowZones, { status: 'ok', dataThrough: '2026-09-04', active: 3, timestamp: fixtureNow - 3600, fetchedAt: fixtureNow, fetchAge: 0, error: null });
});
