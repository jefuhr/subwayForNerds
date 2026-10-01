import { readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TransitService } from '../server/service';
import { FEED_ROUTES } from '../server/transit';
import { decode } from '../server/decode';
import { FleetService, fleetSnapshot } from '../server/fleet';
import { FleetOfflineService } from '../server/fleet-offline';

export const fixtureNow = Date.parse('2026-09-06T00:59:40Z') / 1000;

/** The caller fixes Date.now to fixtureNow for the lifetime of the fixture API. */
export async function createFixtureService() {
  const directory = await mkdtemp(join(tmpdir(), 'sfn-fixture-fleet-'));
  const service = new TransitService({ cacheDir: directory, fetcher: async () => { throw new Error('Fixture service must never request upstream data'); } });
  const close = async () => { await service.stop(); await rm(directory, { recursive: true, force: true }); };
  try {
    for (const id of [...Object.keys(FEED_ROUTES), 'subway-alerts']) {
      const raw = decode(readFileSync(new URL(`fixtures/${id}.pb`, import.meta.url)), id === 'subway-alerts');
      service.accept(id, raw, raw.header.timestamp);
    }
    const fleetFile = join(directory, 'fleet.sqlite');
    service.fleet = new FleetService(fleetFile);
    await service.fleet.ready;
    // Synthetic car assignments on recorded trips, never a live-data dependency.
    const keys = service.boards.get('602')!.departures.map(d => d.tripKey);
    const selected = keys.map(k => service.details.get(k)!.train).find(t => t.trainId && t.assigned !== false)!;
    service.acceptConsists({ trips: [{ tripId: selected.trainId, routeId: selected.route, isAssigned: true, updatedAt: fixtureNow,
      consistCars: ['4149', '4148', '4147', '4146', '4145'].map(number => ({ number, type: 'R211A' })) }] }, fixtureNow);
    const snapshots = [...service.details.values()].flatMap(({ train }) => { const s = fleetSnapshot(train, fixtureNow); return s ? [s] : []; });
    await service.fleet.call('observe', snapshots, fixtureNow);
    service.offline = new FleetOfflineService(fleetFile, join(directory, 'offline'));
    await service.offline.rebuild(fixtureNow);
    return { service, directory, selectedTripKey: selected.key, selectedCarId: 'nyct:R211A:4149', close };
  } catch (error) { await close(); throw error; }
}
