import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { TrackMapPlacement } from '../server/track-map';
import type { TrackMapTopology } from '../shared/track-map';
import type { SourceState, Train } from '../shared/types';
import type { Schedules } from '../server/schedules';
import { serviceTime } from '../server/schedules';

const epoch = 1800000000;
const topology = (): TrackMapTopology => JSON.parse(readFileSync(new URL('./fixtures/track-map-placement/topology.json', import.meta.url), 'utf8'));
const source = (at = epoch, error: string | null = null): SourceState[] => [{ id: 'gtfs', timestamp: at, fetchedAt: at, error }];
const train = (at = epoch): Train => ({
	key: 'gtfs|20270115|t|12:00:00', feed: 'gtfs', serviceDate: '20270115', startTime: '12:00:00', tripId: 't', route: '1',
	destination: 'Gamma', direction: 'NORTH', timestamp: at, alerts: [],
	position: { stopId: 'AN', name: 'Alpha', status: 'STOPPED_AT', timestamp: at },
	stops: [
		{ id: 'AN', name: 'Alpha', arrival: at, departure: at + 10, actualTrack: '1' },
		{ id: 'BN', name: 'Beta', arrival: at + 80, departure: at + 85, actualTrack: '3' },
		{ id: 'CN', name: 'Gamma', arrival: at + 150, departure: at + 155, actualTrack: '5' },
	],
});
const moving = (at = epoch + 10, eta = epoch + 80): Train => {
	const t = train(at); t.position = { stopId: 'BN', name: 'Beta', status: 'IN_TRANSIT_TO', timestamp: at };
	t.stops[1].arrival = eta; return t;
};
const first = (engine: TrackMapPlacement, t: Train, now = t.timestamp, sources = source(now), schedules?: Schedules) => engine.snapshot([t], sources, now, schedules).trains[0];

test('reported stop track is scoped to that stop; position and track certainty remain separate', () => {
	const engine = new TrackMapPlacement(topology());
	const at = first(engine, train());
	assert.equal(at.trackBasis, 'reported'); assert.equal(at.positionBasis, 'reported');
	assert.deepEqual(at.point, { x: 0, y: 0 }); assert.equal(at.motion, undefined);
	const m = first(engine, moving());
	assert.equal(m.trackCode, '3'); assert.equal(m.trackBasis, 'inferred'); assert.equal(m.positionBasis, 'estimated');
	assert.deepEqual(m.motion!.edgeIds, ['ab']);
});

test('fixture trace uses arc length, observed departure and bounded ETA corrections without reversing', () => {
	const engine = new TrackMapPlacement(topology());
	const trace: { at: number; stop: string; status: string; eta?: number; expectedPlacement: string; expectedBasis: string; expectedPoint?: { x: number; y: number } }[] = JSON.parse(readFileSync(new URL('./fixtures/track-map-placement/core-traces.json', import.meta.url), 'utf8'));
	let progress = 0;
	for (const frame of trace) {
		const t = train(epoch + frame.at); t.position = { stopId: frame.stop, name: frame.stop, status: frame.status, timestamp: t.timestamp };
		if (frame.eta) t.stops[1].arrival = epoch + frame.eta;
		const row = first(engine, t);
		assert.equal(row.placement, frame.expectedPlacement); assert.equal(row.positionBasis, frame.expectedBasis);
		if (frame.expectedPoint) assert.deepEqual(row.point, frame.expectedPoint);
		if (row.motion) {
			assert.ok(row.motion.fromProgress >= progress); progress = row.motion.fromProgress;
			assert.ok(row.motion.endTime <= row.staleAt!); assert.ok(row.motion.toProgress <= 1);
		}
	}
});

test('evidence fixture trace freezes source errors and stale motion, then expires without header resurrection', () => {
	const engine = new TrackMapPlacement(topology());
	const trace: { at: number; vehicleAt: number; status: string; sourceError?: string; freshness: string; placement: string; motion: boolean; samePoint?: boolean; observedAt?: number }[] = JSON.parse(readFileSync(new URL('./fixtures/track-map-placement/evidence-traces.json', import.meta.url), 'utf8'));
	let previousPoint;
	for (const frame of trace) {
		const t = frame.status === 'STOPPED_AT' ? train(epoch + frame.vehicleAt) : moving(epoch + frame.vehicleAt, epoch + 200);
		t.timestamp = epoch + frame.at;
		const row = first(engine, t, t.timestamp, source(t.timestamp, frame.sourceError || null));
		assert.equal(row.freshness, frame.freshness); assert.equal(row.placement, frame.placement);
		assert.equal(!!row.motion, frame.motion); assert.equal(row.observedAt, epoch + (frame.observedAt ?? frame.vehicleAt));
		if (frame.samePoint) assert.deepEqual(row.point, previousPoint);
		previousPoint = row.point;
	}
});

test('cold moving/incoming observations hold near the stop without invented progress', () => {
	for (const status of ['IN_TRANSIT_TO', 'INCOMING_AT', 'UNKNOWN']) {
		const t = moving(); t.position!.status = status;
		const row = first(new TrackMapPlacement(topology()), t);
		assert.equal(row.placement, 'near-stop'); assert.equal(row.positionBasis, 'unknown'); assert.equal(row.motion, undefined);
		assert.deepEqual(row.point, { x: 30, y: 40 });
	}
});

test('unknown or ambiguous track stays near the stop; route letters never decide rails', () => {
	const t = train(); t.stops = [t.stops[0]]; delete t.stops[0].actualTrack;
	for (const route of ['1', '7X', 'GS', 'FS', 'H']) {
		t.route = route;
		assert.equal(first(new TrackMapPlacement(topology()), t).placement, 'near-stop');
	}
	t.stops[0].actualTrack = 'not-mapped';
	assert.equal(first(new TrackMapPlacement(topology()), t).trackBasis, 'unknown');
	const inference = train(); delete inference.stops[0].actualTrack;
	assert.equal(first(new TrackMapPlacement(topology()), inference).placement, 'near-stop');
});

test('a sole reviewed platform does not prove every physical choice is mapped when track code is absent', () => {
	const map = topology(); map.coverage.notes.push('Only one reviewed Gamma platform; other physical choices are unresolved');
	const t = train(); t.position!.stopId = 'CN'; delete t.stops[2].actualTrack;
	const row = first(new TrackMapPlacement(map), t);
	assert.equal(row.placement, 'near-stop'); assert.equal(row.trackBasis, 'unknown'); assert.equal(row.positionBasis, 'unknown');
	assert.equal(row.motion, undefined);
	t.stops[2].scheduledTrack = '5';
	assert.equal(first(new TrackMapPlacement(map), t).placement, 'track', 'an applicable explicit code can identify a reviewed platform');
});

test('scheduled track is labeled scheduled rather than reported', () => {
	const t = train(); delete t.stops[0].actualTrack; t.stops[0].scheduledTrack = '1';
	assert.equal(first(new TrackMapPlacement(topology()), t).trackBasis, 'scheduled');
});

test('directed edges and geometric crossings never create invented connections', () => {
	const map = topology(); map.edges = map.edges.filter(e => e.id !== 'ab');
	const e = new TrackMapPlacement(map); first(e, train());
	assert.equal(first(e, moving()).motion, undefined);
	const reverse = new TrackMapPlacement(topology()); const t = train(); t.position!.stopId = 'BN'; first(reverse, t);
	t.timestamp += 10; t.position = { stopId: 'AN', name: 'Alpha', status: 'IN_TRANSIT_TO', timestamp: t.timestamp };
	assert.equal(first(reverse, t).motion, undefined);
});

test('ambiguous parallel paths and nonrevenue edges cannot place moving trains', () => {
	for (const ambiguous of [true, false]) {
		const map = topology();
		if (ambiguous) map.edges.push({ ...map.edges[0], id: 'alternative' }); else map.edges[0].revenue = false;
		const e = new TrackMapPlacement(map); first(e, train()); assert.equal(first(e, moving()).motion, undefined);
	}
});

test('skipped targets are not displayed as occupied platforms and skipped stops do not force a local path', () => {
	const e = new TrackMapPlacement(topology()); const t = train(); t.stops[0].relationship = 'SKIPPED';
	assert.equal(first(e, t).placement, 'near-stop');
	const e2 = new TrackMapPlacement(topology()); first(e2, train());
	const m = moving(); m.position!.stopId = 'CN'; m.stops[1].relationship = 'SKIPPED';
	const row = first(e2, m); assert.deepEqual(row.motion!.edgeIds, ['ab', 'bc']);
});

test('canceled/deleted/unassigned and future trips remain list entries without active markers', () => {
	for (const relationship of ['CANCELED', 'DELETED']) {
		const t = train(); t.relationship = relationship;
		assert.equal(first(new TrackMapPlacement(topology()), t).placement, 'unplaced');
	}
	const t = train(); t.assigned = false;
	assert.equal(first(new TrackMapPlacement(topology()), t).placement, 'unplaced');
	delete t.assigned; assert.equal(first(new TrackMapPlacement(topology()), t).placement, 'track');
	delete t.position; assert.equal(first(new TrackMapPlacement(topology()), t).placement, 'unplaced');
});

test('fresh source headers cannot resurrect stale vehicle timestamps; stale freezes and 300s expires', () => {
	const e = new TrackMapPlacement(topology()); const t = train(); first(e, t);
	for (const age of [90, 91, 300, 301]) {
		t.timestamp = epoch + age;
		const row = first(e, t, epoch + age);
		assert.equal(row.observedAt, epoch);
		assert.equal(row.freshness, age < 90 ? 'live' : age < 300 ? 'stale' : 'unavailable');
		assert.equal(row.placement, age < 300 ? 'track' : 'unplaced'); assert.equal(row.motion, undefined);
	}
});

test('missing vehicle timestamps retain original evidence age on unchanged cached positions', () => {
	const e = new TrackMapPlacement(topology()); const t = train();
	first(e, t); delete t.position!.timestamp; t.timestamp = epoch + 100;
	const row = first(e, t); assert.equal(row.observedAt, epoch); assert.equal(row.freshness, 'stale');

	// A long gap between UI polls is not new vehicle evidence either.
	t.timestamp = epoch + 500;
	assert.equal(first(e, t).placement, 'unplaced');
});

test('a cold report without vehicle age cannot derive a live position from its feed header', () => {
	const t = train(); delete t.position!.timestamp;
	const row = first(new TrackMapPlacement(topology()), t);
	assert.equal(row.observedAt, null); assert.equal(row.freshness, 'unavailable'); assert.equal(row.placement, 'unplaced');
	assert.equal(row.motion, undefined);
});

test('reported intermediate stop sequence constrains the segment, including disconnected stops', () => {
	const e = new TrackMapPlacement(topology()); first(e, train());
	const t = moving(); t.position!.stopId = 'CN';
	t.stops[1].actualTrack = '4'; // The only A-to-C rails pass B track 3, contradicting this stop.
	assert.equal(first(e, t).motion, undefined);
});

test('observed origin cannot prove a code-less target platform in an incomplete mapped subset', () => {
	const e = new TrackMapPlacement(topology()); first(e, train());
	const t = moving(); t.stops = [t.stops[1]]; delete t.stops[0].actualTrack;
	const row = first(e, t);
	assert.equal(row.trackBasis, 'unknown'); assert.equal(row.trackCode, undefined);
	assert.equal(row.placement, 'near-stop'); assert.equal(row.motion, undefined);
});

test('stale ETA corrections do not move a frozen estimate and invalid corrections do not restart motion', () => {
	const e = new TrackMapPlacement(topology()); first(e, train());
	const t = moving(epoch + 10, epoch + 200); first(e, t);
	const frozen = first(e, t, epoch + 110);
	t.stops[1].arrival = epoch + 500;
	assert.deepEqual(first(e, t, epoch + 120).point, frozen.point);

	const e2 = new TrackMapPlacement(topology()); first(e2, train());
	first(e2, moving()); const before = first(e2, moving(epoch + 40));
	const bad = moving(epoch + 45); bad.stops[1].arrival = NaN; first(e2, bad);
	const resumed = first(e2, moving(epoch + 50));
	if (resumed.motion) assert.ok(resumed.motion.fromProgress >= before.motion!.fromProgress);
});

test('old source age and error freeze independently of fresh vehicle evidence', () => {
	const e = new TrackMapPlacement(topology()); first(e, train());
	const t = moving(); const m = first(e, t); assert.ok(m.motion);
	const frozen = first(e, moving(epoch + 40), epoch + 40, source(epoch + 40, 'network down'));
	assert.deepEqual(frozen.point, { x: 30, y: 0 }); assert.equal(frozen.motion, undefined); assert.equal(frozen.freshness, 'stale');
	const old = first(new TrackMapPlacement(topology()), train(epoch + 100), epoch + 100, source(epoch));
	assert.equal(old.freshness, 'stale');
	const missing = first(new TrackMapPlacement(topology()), train(), epoch, []);
	assert.equal(missing.freshness, 'unavailable'); assert.equal(missing.motion, undefined);
});

test('an outage freezes the current bounded estimate without rewinding client interpolation', () => {
	const e = new TrackMapPlacement(topology()); first(e, train()); first(e, moving());
	const failed = first(e, moving(epoch + 40), epoch + 40, source(epoch + 40, 'offline'));
	assert.deepEqual(failed.point, { x: 30, y: 0 });
	assert.equal(failed.motion, undefined);
	assert.deepEqual(first(e, moving(epoch + 60), epoch + 60, source(epoch + 60, 'offline')).point, failed.point);
	assert.equal(failed.observedAt, epoch + 10);
});

test('an older moving packet cannot rewind the estimate clients already interpolated', () => {
	const e = new TrackMapPlacement(topology()); first(e, train()); first(e, moving());
	first(e, moving(epoch + 40));
	const ignored = first(e, moving(epoch + 20), epoch + 50);
	assert.deepEqual(ignored.point, { x: 30, y: 10 });
	assert.equal(ignored.observedAt, epoch + 40);
});

test('motion cannot pass the next reported stop or the original stale deadline', () => {
	const e = new TrackMapPlacement(topology()); first(e, train()); const m = moving(epoch + 10, epoch + 200); first(e, m);
	const row = first(e, m, epoch + 120);
	assert.equal(row.freshness, 'stale'); assert.equal(row.motion, undefined);
	assert.ok(row.point!.x <= 30 && row.point!.y <= 40);
	const frozen = first(e, m, epoch + 160); assert.deepEqual(frozen.point, row.point);
});

test('reroute correction never animates between unrelated rails', () => {
	const e = new TrackMapPlacement(topology()); first(e, train()); first(e, moving());
	const rerouted = moving(epoch + 30); rerouted.stops[1].actualTrack = '4';
	const row = first(e, rerouted); assert.equal(row.motion, undefined); assert.equal(row.placement, 'near-stop');
});

test('next-stop advancement without a new observed departure does not restart on the old rails', () => {
	const e = new TrackMapPlacement(topology()); first(e, train()); first(e, moving()); first(e, moving(epoch + 40));
	const t = moving(epoch + 50); t.position!.stopId = 'CN';
	const row = first(e, t); assert.equal(row.motion, undefined); assert.equal(row.placement, 'near-stop');
});

test('a stale stop report clears an earlier departure origin before the next segment', () => {
	const e = new TrackMapPlacement(topology());
	first(e, train()); first(e, moving());
	const stopped = train(epoch + 20); stopped.position!.stopId = 'BN';
	const atBeta = first(e, stopped, epoch + 120);
	assert.equal(atBeta.freshness, 'stale');
	assert.deepEqual(atBeta.point, { x: 30, y: 40 });
	const onward = moving(epoch + 130); onward.position!.stopId = 'CN';
	const row = first(e, onward);
	assert.equal(row.motion, undefined, 'stale Beta evidence cannot restart a departure from Alpha');
	assert.equal(row.placement, 'near-stop');
	assert.notDeepEqual(row.point, { x: 0, y: 0 });
});

test('interrupting track evidence cannot restart an old moving estimate from zero', () => {
	for (const interruption of ['unknown-status', 'skipped', 'unknown-track']) {
		const e = new TrackMapPlacement(topology()); first(e, train()); first(e, moving());
		const before = first(e, moving(epoch + 40));
		const bad = moving(epoch + 45);
		if (interruption === 'unknown-status') bad.position!.status = 'UNKNOWN';
		if (interruption === 'skipped') bad.stops[1].relationship = 'SKIPPED';
		if (interruption === 'unknown-track') bad.stops[1].actualTrack = 'unmapped';
		first(e, bad);
		const resumed = first(e, moving(epoch + 50));
		if (resumed.motion) assert.ok(resumed.motion.fromProgress >= before.motion!.fromProgress, interruption);
	}
});

test('source errors with no previous placement cannot create a moving or occupied-rail claim', () => {
	for (const t of [train(), moving()]) {
		const row = first(new TrackMapPlacement(topology()), t, t.timestamp, source(t.timestamp, 'offline'));
		assert.equal(row.motion, undefined); assert.notEqual(row.placement, 'track');
	}
});

test('out-of-order vehicle packets cannot rewind a reported platform', () => {
	const e = new TrackMapPlacement(topology());
	const newer = train(epoch + 30); newer.position!.stopId = 'BN';
	first(e, newer);
	const row = first(e, train(), epoch + 40);
	assert.deepEqual(row.point, { x: 30, y: 40 }); assert.equal(row.observedAt, epoch + 30);
});

test('trip identity includes date and start time, duplicate keys prefer newest vehicle observation', () => {
	const e = new TrackMapPlacement(topology()); const a = train(), b = train(epoch - 20), c = train();
	c.startTime = '13:00:00'; c.key = a.key;
	const d = train(); d.serviceDate = '20270116'; d.key = a.key;
	const snapshot = e.snapshot([a, b, c, d], source(), epoch);
	assert.equal(snapshot.trains.length, 3); assert.equal(new Set(snapshot.trains.map(t => t.key)).size, 3);
	assert.ok(snapshot.trains.every(t => t.observedAt === epoch));
});

test('newer cancellation metadata wins deduplication even when it omits an older vehicle report', () => {
	const old = train(), update = train(epoch + 20); update.relationship = 'CANCELED'; delete update.position;
	const snapshot = new TrackMapPlacement(topology()).snapshot([old, update], source(epoch + 20), epoch + 20);
	assert.equal(snapshot.trains.length, 1); assert.equal(snapshot.trains[0].placement, 'unplaced');
	assert.match(snapshot.trains[0].reason!, /canceled/i);
});

test('contradictory duplicate vehicle reports cannot arbitrarily claim one occupied platform', () => {
	const a = train(), b = train(); b.position!.stopId = 'BN';
	const row = new TrackMapPlacement(topology()).snapshot([a, b], source(), epoch).trains[0];
	assert.equal(row.placement, 'unplaced'); assert.match(row.reason!, /conflicting/i);
});

test('invalid/future evidence and nonfinite ETAs never serialize fabricated placement or motion', () => {
	for (const timestamp of [NaN, Infinity, epoch + 100]) {
		const t = train(); t.position!.timestamp = timestamp;
		const row = first(new TrackMapPlacement(topology()), t); assert.equal(row.observedAt, null);
		assert.equal(row.placement, 'unplaced'); assert.equal(row.motion, undefined);
	}
	const e = new TrackMapPlacement(topology()); first(e, train()); const t = moving(); t.stops[1].arrival = NaN;
	assert.equal(first(e, t).motion, undefined);
	assert.throws(() => e.snapshot([], [], NaN), /time/i);
});

test('uniquely matched scheduled segment duration supports explicitly estimated cold motion', () => {
	const date = '20270115', start = serviceTime(date, 43200);
	const schedules: Schedules = { timestamp: start, feeds: [{ name: 'regular', stops: [],
		patterns: [{ route: '1', direction: 0, shape: 's', headsign: 'Gamma', stops: ['AN', 'BN', 'CN'], source: 'static' }],
		trips: [{ id: 't', service: 's', pattern: 0, start: 43200, times: [43200, 43270, 43340] }],
		exceptions: [{ service_id: 's', date, exception_type: '1' }],
	}] };
	const t = moving(start + 35, start + 70);
	const row = first(new TrackMapPlacement(topology()), t, t.timestamp, source(t.timestamp), schedules);
	assert.equal(row.positionBasis, 'estimated'); assert.match(row.reason!, /scheduled/i);
	assert.deepEqual(row.point, { x: 30, y: 5 });
	const engine = new TrackMapPlacement(topology()); first(engine, t, t.timestamp, source(t.timestamp), schedules);
	const polled = first(engine, t, t.timestamp + 5, source(t.timestamp), schedules);
	assert.ok(polled.motion, 'schedule estimate survives repeated polls');
	assert.ok(polled.motion.fromProgress > row.motion!.fromProgress);
	schedules.feeds[0].trips!.push({ id: 't', service: 's', pattern: 0, start: 43200, times: [43200, 43290, 43340] });
	const copy = structuredClone(schedules);
	assert.equal(first(new TrackMapPlacement(topology()), t, t.timestamp, source(t.timestamp), copy).motion, undefined);
});

test('coverage includes uncertain and unplaced rows and excludes other rail systems', () => {
	const a = train(), b = moving(); b.tripId = 'other'; const c = train(); c.tripId = 'future'; delete c.position;
	const other = train(); other.feed = 'path'; other.route = 'PATH';
	const snapshot = new TrackMapPlacement(topology()).snapshot([a, b, c, other], source(), epoch + 10);
	assert.deepEqual(snapshot.coverage, { placed: 1, uncertain: 1, unplaced: 1 });
});
