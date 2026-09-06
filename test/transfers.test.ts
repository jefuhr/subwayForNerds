import { test } from 'node:test';
import assert from 'node:assert/strict';
import { transfers } from '../server/transfers';
import { buildBoard } from '../server/transit';
import type { Station, Train } from '../shared/types';

const now = 1800000000;
const station: Station = { id: 's', name: 'Transfer', borough: 'M', lat: 0, lon: 0, routes: ['Q', 'N'], parts: [{ id: 'A', stationId: 's', name: 'Transfer', line: 'Broadway', routes: ['Q', 'N'], lat: 0, lon: 0, ada: '', adaNotes: '', north: 'North', south: 'South' }] };
const train = (key: string, time: number | null, route = 'Q'): Train => ({ key, feed: 'gtfs-nqrw', tripId: key, route, destination: 'Terminal', direction: 'NORTH', timestamp: now, alerts: [], stops: [{ id: 'AN', sequence: 3, stationId: 's', name: 'Transfer', arrival: time, departure: time == null ? null : time + 20 }] });
function board(trains: Train[], time = now) { return new Map([['s', buildBoard(station, trains, [{ id: 'gtfs-nqrw', timestamp: time, fetchedAt: time, error: null }], [], [station], time)]]); }
test('transfers use raw departure gaps, include same-line alternatives and exclude the incoming train', () => {
  const origin = train('own', now + 120), other = train('other', now + 180), south = train('south', now + 200, 'N'); south.stops[0].id = 'AS';
  const result = transfers(origin, board([origin, other, south]), 'AN', 3, now);
  assert.equal(result.arrival, now + 120); assert.equal(result.connections.length, 2);
  assert.equal(result.connections[0].gap, 80); assert.equal(result.connections[0].basis, 'departure');
  assert.equal(result.connections[1].direction, 'SOUTH');
});
test('unboardable, unassigned, stale, too early/late and physically duplicated trains are excluded', () => {
  const own = train('own', now + 120);
  own.consist = { cars: [{ number: '1', type: 'R160' }], updatedAt: now, fetchedAt: now, source: 'helium' };
  const duplicate = train('dup', now + 180); duplicate.consist = own.consist;
  const canceled = train('cancel', now + 180); canceled.relationship = 'CANCELED';
  const skipped = train('skip', now + 180); skipped.stops[0].relationship = 'SKIPPED';
  const unassigned = train('unassigned', now + 180); unassigned.assigned = false;
  const stale = train('stale', now + 180); stale.timestamp -= 100;
  assert.equal(transfers(own, board([duplicate, canceled, skipped, unassigned, stale, train('early', now + 80), train('late', now + 3000)]), 'AN', 3, now).connections.length, 0);
});
test('missing, skipped, ambiguous and stale origin predictions explain their limitations', () => {
  const own = train('own', null), b = board([]);
  assert.match(transfers(own, b, 'AN', 3, now).message!, /No arrival/);
  own.timestamp -= 100; assert.match(transfers(own, b, 'AN', 3, now).message!, /stale/);
  own.timestamp = now; own.stops.push({ ...own.stops[0], sequence: 4 });
  assert.match(transfers(own, b, 'AN', undefined, now).message!, /ambiguous/);
  assert.match(transfers(own, b, 'AN', 8, now).message!, /removed/);
  own.stops[0].relationship = 'SKIPPED'; assert.match(transfers(own, b, 'AN', 3, now).message!, /not boarding/);
  assert.match(transfers(undefined, b, 'AN', 3, now).message!, /no longer/);
});
test('fallback time bases are explicit and absolute times survive midnight and DST', () => {
  for (const epoch of [Date.parse('2026-11-01T05:59:30Z') / 1000, Date.parse('2026-09-07T03:59:30Z') / 1000]) {
    const own = train('own', epoch + 90), connection = train('other', epoch + 150);
    own.timestamp = connection.timestamp = epoch;
    own.stops[0].arrival = null; connection.stops[0].departure = null;
    const result = transfers(own, board([connection], epoch), 'AN', 3, epoch);
    assert.equal(result.basis, 'departure'); assert.equal(result.connections[0].basis, 'arrival'); assert.equal(result.connections[0].gap, 40);
  }
});
