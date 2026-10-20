import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decode, extension } from '../server/decode';
import { normalizeFeed, normalizeAlerts, buildBoard, FEED_ROUTES, tripKey, patternFor, locationFor, alertActive } from '../server/transit';
import { bundledCatalog } from '../server/catalog';
import trunks from '../data/trunks.json';
import { freshness, countdown, distanceMeters } from '../shared/display';
import type { Departure, ServiceAlert, Train } from '../shared/types';
import { enrichSchedule, type Schedules } from '../server/schedules';
import { TransitService } from '../server/service';

const raw = (feed: string) => decode(readFileSync(new URL(`fixtures/${feed}.pb`, import.meta.url)), feed === 'subway-alerts');
const station = bundledCatalog.find(s => s.id === '602')!;
const base = raw('gtfs');
const now = Number(base.header.timestamp);
const sample = { header: { timestamp: now }, entity: [{ id: 'one', trip_update: { trip: { trip_id: '000001_4..N', start_date: '20260906', route_id: '4', '.transit_realtime.nyct_trip_descriptor': { train_id: 'test call', is_assigned: false } }, stop_time_update: [
  { stop_id: '635N', departure: { time: now + 120 }, '.transit_realtime.nyct_stop_time_update': { scheduled_track: '3', actual_track: '4' } },
  { stop_id: '631N', arrival: { time: now + 400 } },
] } }] };
test('all nine recorded protobuf feeds decode with their correct extension registry', () => {
  for (const feed of [...Object.keys(FEED_ROUTES), 'subway-alerts']) {
    const decoded = raw(feed); assert.ok(decoded.entity.length > 0); assert.ok(decoded.header.timestamp > 0);
    assert.ok(Object.keys(extension(decoded.header, feed === 'subway-alerts' ? 'mercury_feed_header' : 'nyct_feed_header')).length);
  }
  const alerts = normalizeAlerts(raw('subway-alerts')); assert.ok(alerts.length > 100); assert.ok(alerts.some(a => a.updatedAt));
});
test('preserves absent, false, and true assignment as three separate states', () => {
  const trains = [...normalizeFeed('gtfs', base, bundledCatalog).values(), ...normalizeFeed('gtfs-l', raw('gtfs-l'), bundledCatalog).values()];
  assert.ok(trains.some(t => t.assigned === true)); assert.ok(trains.some(t => t.assigned === false)); assert.ok(trains.some(t => !Object.hasOwn(t, 'assigned')));
});
test('keeps scheduled and reported track values separate', () => {
  const trains = normalizeFeed('gtfs', sample, bundledCatalog);
  const board = buildBoard(station, trains.values(), [], [], bundledCatalog, now);
  assert.equal(board.departures.length, 1); assert.equal(board.departures[0].actualTrack, '4'); assert.equal(board.departures[0].scheduledTrack, '3');
  assert.equal(board.departures[0].assigned, false);
});
test('entity renumbering does not change trip identity; service dates and feed namespaces do', () => {
  const changed = structuredClone(sample); changed.entity[0].id = 'different';
  assert.deepEqual([...normalizeFeed('gtfs', changed, bundledCatalog).keys()], [...normalizeFeed('gtfs', sample, bundledCatalog).keys()]);
  const descriptor = sample.entity[0].trip_update.trip;
  assert.notEqual(tripKey('gtfs', descriptor), tripKey('gtfs-l', descriptor));
  assert.notEqual(tripKey('gtfs', descriptor), tripKey('gtfs', { ...descriptor, start_date: '20260907' }));
});
test('joins a recorded vehicle to its trip without inventing a missing status', () => {
  const trains = [...normalizeFeed('gtfs-bdfm', raw('gtfs-bdfm'), bundledCatalog).values()];
  assert.ok(trains.some(t => t.position?.status === 'STOPPED_AT'));
  const unknown = trains.find(t => t.position && !t.position.status)!;
  assert.ok(unknown); assert.match(locationFor(unknown), /^Reported near/);
  const onlyPredictions = [...normalizeFeed('gtfs', sample, bundledCatalog).values()][0];
  assert.match(locationFor(onlyPredictions), /^Next reported stop/);
});
test('separates connected station parts and retains unknown tracks', () => {
  const all = Object.keys(FEED_ROUTES).flatMap(f => [...normalizeFeed(f, raw(f), bundledCatalog).values()]);
  const board = buildBoard(station, all, [], [], bundledCatalog, now);
  assert.ok(new Set(board.departures.map(d => d.partId)).size >= 3);
  const unknown = structuredClone(sample); delete (unknown.entity[0].trip_update.stop_time_update[0] as any)['.transit_realtime.nyct_stop_time_update'];
  const row = buildBoard(station, normalizeFeed('gtfs', unknown, bundledCatalog).values(), [], [], bundledCatalog, now).departures[0];
  assert.equal(row.actualTrack, undefined); assert.equal(row.scheduledTrack, undefined);
});
test('stale, expired, cached, and missing data do not masquerade as live countdowns', () => {
  assert.equal(freshness(now - 91, now), 'stale'); assert.equal(freshness(now - 301, now), 'expired');
  assert.equal(freshness(null, now), 'unavailable'); assert.equal(countdown(now + 61, now, now).value, '1');
  assert.equal(countdown(now + 60, now, now, true).unit, 'last estimate');
  assert.equal(countdown(now + 60, now - 91, now).unit, 'last estimate');
  assert.equal(countdown(null, now, now).unit, 'no estimate');
});
test('absolute predictions survive midnight; expired snapshots retain last-known rows', () => {
  const trains = normalizeFeed('gtfs', sample, bundledCatalog);
  const before = buildBoard(station, trains.values(), [], [], bundledCatalog, now);
  const after = buildBoard(station, trains.values(), [], [], bundledCatalog, now + 86400);
  assert.equal(after.departures[0].time, before.departures[0].time);
  assert.equal(after.departures.length, 1);
});
test('corridor inference uses the remaining stop pattern, never the usual route label', () => {
  const train = [...normalizeFeed('gtfs', sample, bundledCatalog).values()][0];
  assert.match(patternFor(train, '635N', bundledCatalog).label, /Lex express/);
  const local = { ...train, stops: ['635N','634N','633N','632N','631N'].map(id => ({ id, name: id, arrival: now + 300, departure: null })) };
  assert.equal(patternFor(local, '635N', bundledCatalog).label, 'Lex local');
  assert.equal(patternFor(local, '635N', bundledCatalog).source, 'inferred');
});
test('alerts respect active periods and nearby distance is sensible', () => {
  const alert = { periods: [{ start: now + 30, end: now + 60 }] } as ServiceAlert;
  assert.equal(alertActive(alert, now), false); assert.equal(alertActive(alert, now + 45), true);
  assert.equal(alertActive(alert, now + 60), false);
  assert.equal(distanceMeters(40, -73, 40, -73), 0);
  assert.ok(distanceMeters(40, -73, 40.01, -73) > 1100);
});
test('Brighton is segmented from the combined Broadway–Brighton metadata line', () => {
  const train = [...normalizeFeed('gtfs', sample, bundledCatalog).values()][0];
  const brighton = { ...train, route: 'B', stops: ['D26S','D28S','D31S','D35S','D39S','D40S'].map(id => ({ id, name: id, arrival: now + 300, departure: null })) };
  assert.equal(patternFor(brighton, 'D26S', bundledCatalog).label, '6 Av–Brighton express');
  const local = { ...brighton, route: 'Q', stops: ['D26S','D27S','D28S','D29S'].map(id => ({ id, name: id, arrival: now + 300, departure: null })) };
  assert.equal(patternFor(local, 'D26S', bundledCatalog).label, 'Broadway–Brighton local');
  const branched = { ...local, stops: [local.stops[0], { id: 'R30S', name: 'DeKalb', arrival: now + 50, departure: null }, local.stops[2]] };
  assert.equal(patternFor(branched, 'D26S', bundledCatalog).label, 'Broadway–Brighton');
});
test('static patterns enrich only compatible trips and never change realtime times', () => {
  const train = [...normalizeFeed('gtfs', sample, bundledCatalog).values()][0];
  const schedules = { timestamp: now, feeds: [{ name: 'gtfs_subway', stops: [], patterns: [{ shape: '4..N', route: '4', headsign: 'A scheduled destination', source: 'gtfs_subway', stops: ['635N','634N','633N','632N','631N'] }] }] };
  const enriched = enrichSchedule(structuredClone(train), schedules);
  assert.ok(enriched.scheduledPattern); assert.deepEqual(enriched.stops, train.stops); assert.equal(enriched.destination, train.destination);
  assert.equal(enrichSchedule({ ...train, stops: [...train.stops].reverse() }, schedules).scheduledPattern, undefined);
});
test('shuttles and SIR retain their expected feed source even with no departures', () => {
  for (const [line, feed] of [['Staten Island','gtfs-si'],['Franklin Shuttle','gtfs-bdfm'],['Lexington - Shuttle','gtfs']]) {
    const selected = bundledCatalog.find(s => s.parts.some(p => p.line === line))!;
    const board = buildBoard(selected, [], [{ id: feed, timestamp: null, fetchedAt: null, error: 'Unavailable' }], [], bundledCatalog, now);
    assert.ok(board.sources.some(s => s.id === feed));
  }
});
test('agency-wide alerts remain visible and selector constraints stay together', () => {
  const global = { id: 'all', title: 'System notice', description: '', routes: [], stops: [], selectors: [{}], periods: [] };
  const unrelated = { ...global, id: 'other', routes: ['A'], stops: ['635N'], selectors: [{ route: 'A', stop: '635N' }] };
  const board = buildBoard(station, [], [], [global, unrelated], bundledCatalog, now);
  assert.deepEqual(board.alerts.map(a => a.id), ['all']);
});

const labelTrain = (route: string, ids: string[]): Train => ({
	...[...normalizeFeed('gtfs', sample, bundledCatalog).values()][0], route,
	stops: ids.map(id => ({ id, name: id, arrival: now + 300, departure: null })),
});
test('trunk labels follow each train path and fall back to its normal trunk beyond the core', () => {
	const cases: [string, string[], string][] = [
		['G', ['F25N', 'F24N', 'G22N'], 'Crosstown–Culver'],
		['G', ['F25S', 'F26S', 'F27S'], 'Crosstown–Culver'],
		['F', ['F25N', 'F24N', 'D19N'], '6 Av–Culver'],
		['B', ['D31S', 'D35S', 'D39S'], '6 Av–Brighton express'],
		['Q', ['D31S', 'D32S', 'D33S'], 'Broadway–Brighton local'],
		['C', ['A45N', 'D21N', 'D20N', 'D19N'], '6 Av–Fulton St'],
		['C', ['A45S', 'A46S', 'A47S'], '8 Av–Fulton St'],
		['B', ['A22N', 'A21N', 'A20N'], '6 Av'],
		['B', ['A24N', 'A22N', 'A21N'], '6 Av'],
		['E', ['G08N', 'G07N', 'G06N'], '8 Av–Queens Blvd'],
		['M', ['D19S', 'D20S', 'F15S', 'M18S'], '6 Av'],
		['GS', ['901N', '902N'], '42 St Shuttle'],
		['FS', ['S01S', 'S03S'], 'Franklin Shuttle'],
		['H', ['H12N', 'H13N'], 'Rockaway Shuttle'],
	];
	for (const [route, ids, expected] of cases) {
		assert.equal(patternFor(labelTrain(route, ids), ids[0], bundledCatalog).label, expected, `${route} at ${ids[0]}`);
	}
});
test('a full scheduled reroute retains its actual trunk after the realtime core stops have passed', () => {
	const train = labelTrain('C', ['A45S', 'A46S', 'A47S']);
	train.scheduledPattern = { shape: 'C.reroute', headsign: 'Euclid Av', source: 'gtfs_supplemented', stops: ['D15S', 'D16S', 'D17S', 'D20S', 'D21S', 'A45S', 'A46S', 'A47S'] };
	assert.deepEqual(patternFor(train, 'A45S', bundledCatalog), { label: '6 Av–Fulton St', source: 'static' });
});
test('departure core wins locally and multiple deviations use the most witnessed core stops', () => {
	assert.equal(patternFor(labelTrain('M', ['D19S', 'M18S', 'M19S', 'M20S', 'M21S']), 'D19S', bundledCatalog).label, '6 Av');
	assert.equal(patternFor(labelTrain('C', ['A45N', 'D21N', 'D20N', 'R20N']), 'A45N', bundledCatalog).label, '6 Av–Fulton St');
});
test('boarding area omits the line at single-segment stations and uses short segments at complexes', () => {
	const boards = [
		{ stop: 'F25N', route: 'G', track: 'B2', area: 'Northbound · Track B2' },
		{ stop: 'D24N', route: 'B', track: 'A4', area: 'Brighton · Manhattan · Track A4' },
	];
	for (const { stop, route, track, area } of boards) {
		const selected = bundledCatalog.find(s => s.parts.some(p => p.id === stop.slice(0, -1)))!;
		const train = labelTrain(route, [stop]); train.stops[0].actualTrack = track;
		const board = buildBoard(selected, [train], [], [], bundledCatalog, now);
		assert.equal(board.departures[0].area, area);
		for (const row of board.departures) assert.doesNotMatch(`${row.area} ${row.pattern}`, /6th Av - Culver|Broadway - Brighton/);
	}
});
test('unknown routes retain short segment labels or the service pattern fallback', () => {
	assert.equal(patternFor(labelTrain('unknown', ['F25N']), 'F25N', bundledCatalog).label, 'Culver');
	assert.deepEqual(patternFor(labelTrain('unknown', ['unknownN']), 'unknownN', bundledCatalog), { label: 'Service pattern', source: 'static' });
});

test('DeKalb junction shows the train trunk without choosing a branch', () => {
	for (const [route, expected] of [['B', '6 Av'], ['Q', 'Broadway'], ['R', 'Broadway']]) {
		const train = labelTrain(route, ['R30N']);
		assert.equal(patternFor(train, 'R30N', bundledCatalog).label, expected);
		const station = bundledCatalog.find(s => s.parts.some(p => p.id === 'R30'))!;
		assert.equal(buildBoard(station, [train], [], [], bundledCatalog, now).departures[0].area, 'Manhattan');
	}
});

test('shared junctions do not impose another route branch on a train', () => {
	for (const [stop, route, expected] of [
		['D42N', 'F', '6 Av'], ['D42N', 'Q', 'Broadway'],
		['A41N', 'A', '8 Av'], ['A41N', 'F', '6 Av'],
		['A42N', 'C', '8 Av'], ['A42N', 'G', 'Crosstown'],
	]) assert.equal(patternFor(labelTrain(route, [stop]), stop, bundledCatalog).label, expected);
});

test('trunk cores exclude shared approaches independently of route preference', () => {
	const eighth = trunks.find(trunk => trunk.name === '8 Av')!;
	assert.ok(!trunks.find(trunk => trunk.name === 'Nassau')!.stops.includes('M18'));
	for (const stop of ['A12', 'A14', 'A15', 'A16', 'A17', 'A18', 'A19', 'A20', 'A21', 'A22', 'A24']) {
		assert.ok(!eighth.stops.includes(stop), `8 Av core excludes shared CPW stop ${stop}`);
	}
});
test('branch labels cover Nassau, White Plains Road, Second Avenue and Fourth Avenue', () => {
	for (const [route, stop, expected] of [
		['J', 'M11N', 'Nassau–Jamaica'], ['5', '204N', 'Lex–White Plains Rd'],
		['Q', 'Q03N', 'Broadway–Second Av'], ['D', 'R31S', '6 Av–4 Av'],
	]) assert.equal(patternFor(labelTrain(route, [stop]), stop, bundledCatalog).label, expected);
	const sirStop = bundledCatalog.find(station => station.parts.some(part => part.line === 'Staten Island'))!.parts[0].id;
	assert.equal(patternFor(labelTrain('SIR', [sirStop + 'N']), sirStop + 'N', bundledCatalog).label, 'Staten Island');
});

test('a partial reroute uses the departure core and the deviation beyond either core', () => {
	const ids = ['A45N', 'A38N', 'A36N', 'A34N', 'A33N', 'A32N', 'D20N', 'D17N', 'D16N', 'D15N'];
	const train = labelTrain('C', ids);
	assert.equal(patternFor(train, 'D16N', bundledCatalog).label, '6 Av');
	assert.equal(patternFor(train, 'A36N', bundledCatalog).label, '8 Av');
	assert.equal(patternFor(train, 'A45N', bundledCatalog).label, '6 Av–Fulton St');
	const scheduled = { ...labelTrain('C', ['A45N']), scheduledPattern: {
		shape: 'C.partial-reroute', headsign: 'Uptown', source: 'gtfs_supplemented', stops: ids,
	} };
	assert.equal(patternFor(scheduled, 'A45N', bundledCatalog).label, '6 Av–Fulton St');
});

const genericSouthboundF = () => ({ ...labelTrain('F', ['F21S', 'F22S', 'F25S', 'F26S', 'F27S']),
	tripId: '128300_F..S', serviceDate: '20261019', direction: 'SOUTH',
});
function genericFSchedules(): Schedules {
	return { version: 2, timestamp: now, feeds: [
		{ name: 'gtfs_subway', stops: [],
			patterns: [{ route: 'F', shape: 'F.regular..S', headsign: 'Coney Island', direction: 1, source: 'gtfs_subway', stops: ['D15S', 'D16S', 'D17S', 'D20S', 'F18S', 'F21S', 'F22S', 'F25S', 'F26S', 'F27S'] }],
			trips: [{ id: 'REGULAR_128300_F.regular..S', service: 'work', pattern: 0, start: 46080, times: [] }],
			exceptions: [{ service_id: 'work', date: '20261019', exception_type: '1' }],
		},
		{ name: 'gtfs_supplemented', stops: [],
			patterns: [{ route: 'F', shape: 'F.planned..S', headsign: 'Coney Island', direction: 1, source: 'gtfs_supplemented', stops: ['A27S', 'A28S', 'A31S', 'A32S', 'A38S', 'F21S', 'F22S', 'F25S', 'F26S', 'F27S'] }],
			trips: [{ id: 'PLANNED_128300_F.planned..S', service: 'work', pattern: 0, start: 46080, times: [] }],
			exceptions: [{ service_id: 'work', date: '20261019', exception_type: '1' }],
		},
	] };
}
test('generic-shape F board labels prefer a same-origin supplemented trip without enriching its strict shape', () => {
	const train = genericSouthboundF(), schedules = genericFSchedules();
	assert.equal(enrichSchedule(train, schedules).scheduledPattern, undefined);
	assert.deepEqual(patternFor(train, 'F25S', bundledCatalog, schedules), { label: '8 Av–Culver', source: 'static' });
	const station = bundledCatalog.find(s => s.parts.some(p => p.id === 'F25'))!;
	assert.equal(buildBoard(station, [train], [], [], bundledCatalog, now, schedules).departures[0].pattern, '8 Av–Culver');
	assert.equal(train.scheduledPattern, undefined);
});
test('generic-shape F falls back to the matched regular trip when no supplemented trip matches', () => {
	const schedules = genericFSchedules(); schedules.feeds[1].trips![0].id = 'PLANNED_999999_F.planned..S';
	assert.equal(patternFor(genericSouthboundF(), 'F25S', bundledCatalog, schedules).label, '6 Av–Culver');
});
test('generic-shape F retains its normal fallback without a unique v2 schedule match', () => {
	const schedules = genericFSchedules();
	for (const feed of schedules.feeds) feed.trips![0].id = 'OTHER_999999_F..S';
	assert.equal(patternFor(genericSouthboundF(), 'F25S', bundledCatalog, schedules).label, '6 Av–Culver');
});
test('v1 and omitted schedules retain the generic-shape F fallback', () => {
	const train = genericSouthboundF(), schedules = genericFSchedules(); schedules.version = 1;
	assert.equal(patternFor(train, 'F25S', bundledCatalog, schedules).label, '6 Av–Culver');
	assert.equal(patternFor(train, 'F25S', bundledCatalog).label, '6 Av–Culver');
});
test('an existing strict scheduledPattern takes precedence over origin matching for board labels', () => {
	const train = { ...genericSouthboundF(), scheduledPattern: {
		shape: 'F..S', headsign: 'Coney Island', source: 'gtfs_subway', stops: ['D16S', 'D17S', 'F21S', 'F25S'],
	} };
	assert.equal(patternFor(train, 'F25S', bundledCatalog, genericFSchedules()).label, '6 Av–Culver');
});
test('service board refresh passes v2 schedules to generic-shape trunk detection', async () => {
	const service = new TransitService({ trackMapTopology: null });
	try {
		service.schedules = genericFSchedules();
		const train = genericSouthboundF(); service.slots.get('gtfs-bdfm')!.trains.set(train.key, train);
		service.refreshBoards(now);
		const station = bundledCatalog.find(s => s.parts.some(p => p.id === 'F25'))!;
		assert.equal(service.boards.get(station.id)!.departures[0].pattern, '8 Av–Culver');
		assert.equal(train.scheduledPattern, undefined);
	} finally { await service.stop(); }
});

test('a regular-only same-origin match can recover a non-normal trunk too', () => {
	const schedules = genericFSchedules();
	schedules.feeds = [schedules.feeds[0]];
	schedules.feeds[0].patterns[0].stops = ['A27S', 'A28S', ...genericSouthboundF().stops.map(stop => stop.id)];
	assert.equal(patternFor(genericSouthboundF(), 'F25S', bundledCatalog, schedules).label, '8 Av–Culver');
});
test('board trunk-path memo matches a multi-part train only once and resets for the next build', () => {
	const schedules = genericFSchedules(), planned = schedules.feeds[1], exceptions = planned.exceptions;
	let matches = 0;
	Object.defineProperty(planned, 'exceptions', { get() { matches++; return exceptions; } });
	const train = genericSouthboundF();
	const selected = bundledCatalog.find(s => s.parts.some(p => p.id === 'F25'))!;
	const station = { ...selected, parts: ['F21', 'F25'].map(id => bundledCatalog.flatMap(s => s.parts).find(part => part.id === id)!) };
	const first = buildBoard(station, [train], [], [], bundledCatalog, now, schedules);
	assert.equal(first.departures.length, 2);
	assert.ok(first.departures.every(departure => departure.pattern === '8 Av–Culver'));
	assert.equal(matches, 1);
	buildBoard(station, [train], [], [], bundledCatalog, now, schedules);
	assert.equal(matches, 2, 'memo is scoped to one board build');
});

test('origin-matched trunk context rejects a supplemented path incompatible with actual 6 Av stops', () => {
	const train = { ...genericSouthboundF(), stops: labelTrain('F', ['D16S', 'D17S', 'D20S', 'F21S', 'F22S', 'F25S', 'F26S', 'F27S']).stops };
	const schedules = genericFSchedules();
	assert.equal(patternFor(train, 'F25S', bundledCatalog, schedules).label, '6 Av–Culver');
	schedules.feeds = [schedules.feeds[1]];
	assert.equal(patternFor(train, 'F25S', bundledCatalog, schedules).label, '6 Av–Culver', 'incompatible paths leave only realtime context');
	assert.equal(train.scheduledPattern, undefined);
});
test('origin-matched trunk context requires the remaining stops in order', () => {
	const train = { ...genericSouthboundF(), stops: labelTrain('F', ['F22S', 'F21S', 'F25S']).stops };
	assert.equal(patternFor(train, 'F25S', bundledCatalog, genericFSchedules()).label, '6 Av–Culver');
});
test('skipped realtime stops do not reject an otherwise compatible origin-matched path', () => {
	const train = { ...genericSouthboundF(), stops: labelTrain('F', ['F21S', 'D16S', 'F25S']).stops };
	train.stops[1].relationship = 'SKIPPED';
	assert.equal(patternFor(train, 'F25S', bundledCatalog, genericFSchedules()).label, '8 Av–Culver');
});
