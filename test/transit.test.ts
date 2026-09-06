import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decode, extension } from '../server/decode';
import { normalizeFeed, normalizeAlerts, buildBoard, FEED_ROUTES, tripKey, patternFor, locationFor, alertActive } from '../server/transit';
import { bundledCatalog } from '../server/catalog';
import { freshness, countdown, distanceMeters } from '../shared/display';
import type { Departure, ServiceAlert, Train } from '../shared/types';
import { enrichSchedule } from '../server/schedules';

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
  assert.equal(patternFor(brighton, 'D26S', bundledCatalog).label, 'Brighton express');
  const local = { ...brighton, stops: ['D26S','D27S','D28S','D29S'].map(id => ({ id, name: id, arrival: now + 300, departure: null })) };
  assert.equal(patternFor(local, 'D26S', bundledCatalog).label, 'Brighton local');
  const branched = { ...local, stops: [local.stops[0], { id: 'R30S', name: 'DeKalb', arrival: now + 50, departure: null }, local.stops[2]] };
  assert.equal(patternFor(branched, 'D26S', bundledCatalog).label, 'Brighton');
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
