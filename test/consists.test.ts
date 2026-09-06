import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeConsists, enrichConsist, HELIUM_URL } from '../server/consists';
import { consistSummary, currentConsist } from '../shared/consist';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';
import type { Train } from '../shared/types';

const now = Math.floor(Date.now() / 1000);
const trip = { tripId: '1C 1124 EUC/168', routeId: 'C', isAssigned: true, updatedAt: now,
  consistCars: [{ number: '4149', type: 'R211A' }, { number: '4148', type: 'R211A' }, { number: '4374', type: 'R211A' }] };
const payload = (trips: unknown[] = [trip]) => ({ trips, staleRouteIds: [] });
const train = (): Train => ({ key: 'test', feed: 'gtfs-ace', tripId: '68400_C..N', trainId: trip.tripId,
  route: 'C', destination: '168 St', direction: 'NORTH', timestamp: now, stops: [], alerts: [] });

test('Helium joins on operations ID and preserves car strings, equipment and order', () => {
  const trips = normalizeConsists(payload(), now), t = train();
  enrichConsist(t, trips, now);
  assert.deepEqual(t.consist?.cars, trip.consistCars);
  assert.equal(t.consist?.source, 'helium');
  assert.equal(consistSummary(t.consist!.cars), '4149–4148, 4374');
  assert.equal(consistSummary([{ number: '0012' }, { number: '0013' }, { number: '0010' }]), '0012–0013, 0010');
  const wrongId = { ...train(), trainId: train().tripId };
  enrichConsist(wrongId, trips, now); assert.equal(wrongId.consist, undefined);
  for (const change of [{ route: 'A' }, { assigned: false }, { timestamp: now - 301 }]) {
    const other = { ...train(), ...change }; enrichConsist(other, trips, now); assert.equal(other.consist, undefined);
  }
  enrichConsist(t, trips, now + 301); assert.equal(t.consist, undefined);
});

test('missing, stale, malformed, unassigned and ambiguous consists remain unknown', () => {
  for (const change of [{ consistCars: null }, { consistCars: [] }, { consistCars: [{ number: 4149 }] },
    { consistCars: [{ number: '4149' }, { number: '4149' }] }, { updatedAt: null },
    { updatedAt: now - 301 }, { updatedAt: now + 120 }, { isAssigned: false }]) {
    assert.equal(normalizeConsists(payload([{ ...trip, ...change }]), now).size, 0);
  }
  assert.equal(normalizeConsists({ ...payload(), staleRouteIds: ['C'] }, now).size, 0);
  assert.equal(normalizeConsists(payload([trip, { ...trip, consistCars: null }, trip]), now).size, 0);
  assert.equal(normalizeConsists(payload([null, {}, trip]), now).size, 1);
  assert.throws(() => normalizeConsists({ error: 'unavailable' }, now));
  const consist = normalizeConsists(payload(), now).get(trip.tripId)!.consist;
  assert.equal(currentConsist({ ...consist, fetchedAt: now - 301 }, now), false);
});

test('independent Helium refresh enriches board and trip APIs and clears removed cars', async () => {
  let response = payload(), fail = false, requests = 0;
  const service = new TransitService({ fetcher: (async (url: string) => {
    requests++; assert.equal(url, HELIUM_URL);
    if (fail) throw new Error('Helium unavailable');
    return new Response(JSON.stringify(response));
  }) as typeof fetch });
  const raw = { header: { timestamp: now }, entity: [{ trip_update: { trip: {
    trip_id: train().tripId, route_id: 'C', start_date: '20260906',
    '.transit_realtime.nyct_trip_descriptor': { train_id: trip.tripId, is_assigned: true },
  }, stop_time_update: [{ stop_id: 'A32N', departure: { time: now + 120 } }] } }] };
  service.accept('gtfs-ace', raw, now);
  const stationId = service.catalog.find(s => s.parts.some(p => p.id === 'A32'))!.id;
  const app = await createServer(service);
  const url = `/subwaysForNerds/api/v1/stations/${stationId}/board`;
  try {
    const before = await app.inject(url);
    await service.refreshConsists();
    const after = await app.inject(url);
    assert.notEqual(before.headers.etag, after.headers.etag);
    const departure = after.json().departures[0];
    assert.deepEqual(departure.consist.cars, trip.consistCars);
    const detail = await app.inject('/subwaysForNerds/api/v1/trips?key=' + encodeURIComponent(departure.tripKey));
    assert.deepEqual(detail.json().train.consist, departure.consist);
    assert.equal(requests, 1);
    // A new GTFS snapshot also picks up the existing Helium cache.
    service.accept('gtfs-ace', { ...raw, header: { timestamp: now + 30 } }, now + 30);
    assert.ok(service.boards.get(stationId)!.departures[0].consist);
    fail = true;
    await assert.rejects(service.refreshConsists(), /Helium unavailable/);
    assert.equal(service.slots.get('gtfs-ace')!.state.error, null);
    assert.ok(service.boards.get(stationId)!.departures[0].consist);
    service.refreshBoards(now + 301);
    assert.equal(service.boards.get(stationId)!.departures[0].consist, undefined);
    fail = false; response = payload([]);
    await service.refreshConsists();
    assert.equal(service.boards.get(stationId)!.departures[0].consist, undefined);
    assert.equal(service.consistState.error, null);
    // Malformed successes are treated as upstream failures, not missing trains.
    response = {} as typeof response;
    await assert.rejects(service.refreshConsists(), /Unexpected Helium/);
    assert.ok(service.boards.get(stationId)!.departures.length);
  } finally { await app.close(); }
});
