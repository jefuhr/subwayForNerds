import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { FleetStore } from '../server/fleet-store.mjs';
import { fleetSnapshot } from '../server/fleet';
import type { FleetSnapshot } from '../shared/fleet';
import type { Train } from '../shared/types';

const now = 1800000000;
const raw = (number: string, equipment = 'R160') => ({ car_number: number, car_class: equipment, retirement_date: 'In-Service' });
const snapshot = (numbers = ['1', '2'], timestamp = now, location = 'At Test'): FleetSnapshot => ({ namespace: 'nyct', cars: numbers.map(number => ({ number, type: 'R160A' })), observation: { timestamp, location, locationTimestamp: timestamp, route: 'E', tripKey: 'trip', next: { name: 'Next', time: timestamp + 90 } } });

test('inventory deduplicates identical records and isolates reused numbers and conflicting status', () => {
  const db = new FleetStore(':memory:');
  try {
    db.importRoster([raw('1'), raw('1'), raw('1', 'R32'), { ...raw('2'), retirement_date: 'Unknown - Retired' }, raw('2')], '2026-09-06', 1);
    assert.equal(db.all(now).length, 3);
    db.importRoster([{ ...raw('4'), controller: 'AL' }, { ...raw('4'), controller: 'GE' }], '2026-09-06', 1);
    assert.equal(db.detail('nyct:R160:4', now)!.cars[0].facts!.controller, 'Conflicting source records');
    assert.match(db.detail('nyct:R160:1', now)!.cars[0].conflicts![0], /reused/);
    assert.equal(db.detail('nyct:R160:2', now)!.cars[0].lifecycle, 'Conflicting roster status');
    db.observe([snapshot(['1'])], now);
    assert.equal(db.detail('nyct:R32:1', now)!.cars[0].last, undefined);
    assert.equal(db.detail('nyct:R160:1', now)!.cars[0].reporting, true);
    assert.throws(() => db.importRoster([], '2026-09-07'), /Incomplete/);
    assert.equal(db.all(now).length, 4);
  } finally { db.close(); }
});
test('observations are monotonic, grouped, deduplicated and retain historical formations', () => {
  const db = new FleetStore(':memory:');
  try {
    db.observe([snapshot()], now);
    const first = db.list({}, now).rows[0]; assert.equal(first.cars.length, 2);
    db.observe([snapshot()], now); assert.equal(db.detail(first.id, now)!.history.length, 1);
    db.observe([snapshot(['1', '2'], now - 10, 'Old')], now);
    assert.equal(db.detail('nyct:R160:1', now)!.cars[0].last!.location, 'At Test');
    db.observe([snapshot(['2', '1'], now + 10)], now + 10);
    assert.equal(db.list({}, now + 10).rows[0].id, first.id);
    assert.equal(db.list({}, now + 10).rows[0].cars[0].number, '2');
    assert.equal(db.detail(first.id, now + 10)!.cars[0].number, '2');
    db.observe([snapshot(['1', '3'], now + 20)], now + 20);
    assert.deepEqual(db.detail(first.id, now + 20)!.cars.map(c => c.number).sort(), ['1', '2']);
    assert.equal(db.detail('nyct:R160:2', now + 20)!.cars[0].reporting, false);
    assert.equal(db.list({}, now + 20).rows.filter(r => r.reporting).length, 1);
    db.observe([], now + 21); assert.equal(db.list({}, now + 21).rows.some(r => r.reporting), false);
  } finally { db.close(); }
});
test('ambiguous simultaneous claims do not acquire a physical identity or current position', () => {
  const db = new FleetStore(':memory:');
  try {
    db.observe([snapshot()], now);
    db.observe([snapshot(['1', '2'], now + 10), snapshot(['1', '3'], now + 10)], now + 10);
    assert.equal(db.all(now + 10).filter(c => c.reporting).length, 0);
    assert.equal(db.detail('nyct:R160:1', now)!.history.length, 1);
  } finally { db.close(); }
});
test('sourced home yards, aliases and linked sets remain independent of observations', () => {
  const db = new FleetStore(':memory:');
  try {
    db.importSupplement({ cars: [{ id: 'nyct:R156:0L912', number: '0L912', equipment: 'R156', category: 'work', aliases: ['OL912'], lifecycle: 'Unverified', evidence: [{ url: 'https://example.org', date: '2026-01-01', note: 'Test' }] }], sources: [], yardRules: [{ routes: ['E'], name: 'Jamaica', date: '2026-01-01', url: 'https://example.org', note: 'Test' }] });
    assert.equal(db.list({ q: 'OL912' }, now).total, 1);
    assert.equal(db.list({ q: 'OL912' }, now).rows[0].cars[0].last, undefined);
    db.observe([snapshot()], now); db.observe([], now + 1);
    assert.equal(db.detail('nyct:R160:1', now + 1)!.cars[0].estimatedYard!.name, 'Jamaica');
    assert.equal(db.detail('nyct:R160:1', now + 31 * 86400)!.cars[0].estimatedYard, undefined);
  } finally { db.close(); }
});
test('backup and restart preserve last seen; retention removes events, never the last report', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'sfn-fleet-test-'));
  let db: FleetStore | undefined;
  try {
    db = new FleetStore(join(dir, 'fleet.sqlite')); db.observe([snapshot()], now);
    db.backup(join(dir, 'backup.sqlite')); db.close();
    db = new FleetStore(join(dir, 'backup.sqlite'));
    assert.equal(db.detail('nyct:R160:1', now)!.cars[0].last!.timestamp, now);
    assert.equal(db.detail('nyct:R160:1', now)!.cars[0].reporting, false);
    db.cleanup(now + 31 * 86400);
    assert.equal(db.detail('nyct:R160:1', now + 31 * 86400)!.history.length, 0);
    assert.equal(db.detail('nyct:R160:1', now + 31 * 86400)!.cars[0].last!.timestamp, now);
  } finally { db?.close(); await rm(dir, { recursive: true, force: true }); }
});
test('next stop skips the current platform, skipped and passed predictions', () => {
  const train: Train = { key: 't', tripId: 't', route: 'E', feed: 'gtfs-ace', destination: 'End', direction: 'NORTH', timestamp: now, alerts: [],
    consist: { cars: [{ number: '1', type: 'R160' }], updatedAt: now, fetchedAt: now, source: 'helium' },
    position: { stopId: 'A', name: 'Current', status: 'STOPPED_AT', timestamp: now }, stops: [
      { id: 'A', name: 'Current', arrival: now, departure: now + 20 },
      { id: 'B', name: 'Skipped', relationship: 'SKIPPED', arrival: now + 30, departure: now + 30 },
      { id: 'C', name: 'Next', arrival: now + 90, departure: now + 100 },
    ] };
  assert.equal(fleetSnapshot(train, now)!.observation.next!.name, 'Next');
  train.stops = []; assert.equal(fleetSnapshot(train, now)!.observation.next, undefined);
  train.assigned = false; assert.equal(fleetSnapshot(train, now), undefined);
});
