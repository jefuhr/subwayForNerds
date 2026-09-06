import { readFileSync } from 'node:fs';
import { createServer } from '../server/index';
import { TransitService } from '../server/service';
import { FEED_ROUTES } from '../server/transit';
import { decode } from '../server/decode';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { FleetService, fleetSnapshot } from '../server/fleet';

const fixtureNow = Date.parse('2026-09-06T00:59:40Z') / 1000;
Date.now = () => fixtureNow * 1000;

const service = new TransitService();
for (const id of [...Object.keys(FEED_ROUTES), 'subway-alerts']) {
  const raw = decode(readFileSync(new URL(`fixtures/${id}.pb`, import.meta.url)), id === 'subway-alerts');
  service.accept(id, raw, raw.header.timestamp);
}
const fleetDir = await mkdtemp(join(tmpdir(), 'sfn-browser-fleet-'));
service.fleet = new FleetService(join(fleetDir, 'fleet.sqlite'));
await service.fleet.ready;
// Synthetic car assignments on recorded trips, never a live-data dependency.
const keys = service.boards.get('602')!.departures.map(d => d.tripKey);
const selected = keys.map(k => service.details.get(k)!.train).find(t => t.trainId && t.assigned !== false)!;
service.acceptConsists({ trips: [{ tripId: selected.trainId, routeId: selected.route, isAssigned: true, updatedAt: fixtureNow,
  consistCars: ['4149', '4148', '4147', '4146', '4145'].map(number => ({ number, type: 'R211A' })) }] }, fixtureNow);
const snapshots = [...service.details.values()].flatMap(({ train }) => { const s = fleetSnapshot(train, fixtureNow); return s ? [s] : []; });
await service.fleet.call('observe', snapshots, fixtureNow);
const app = await createServer(service);
await app.listen({ host: '127.0.0.1', port: 8092 });
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => { void app.close().then(() => rm(fleetDir, { recursive: true, force: true })).then(() => process.exit(0)); });
