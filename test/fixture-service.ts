import { readFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TransitService } from '../server/service';
import { FEED_ROUTES } from '../server/transit';
import { decode } from '../server/decode';
import { FleetService, fleetSnapshot } from '../server/fleet';
import { FleetOfflineService } from '../server/fleet-offline';
import { FleetPackService } from '../server/fleet-pack';
import type { SlowZoneRow } from '../server/slow-zones';

export const fixtureNow = Date.parse('2026-09-06T00:59:40Z') / 1000;
// Synthetic Transit Lab rows for recorded trains: a 4 train incoming at 23 St, a disruption
// further along its route, and a zone ahead of the selected L train. Inactive and
// excluded kinds prove filtering; none of these describe real track conditions.
const zoneRow = (a: string, b: string, segment: string, routes: string, patch: Partial<SlowZoneRow> = {}): SlowZoneRow => ({ a_stop: a, b_stop: b, segment, routes,
  start_date: '2026-08-10', end_date: '2026-09-04', slow_days: 20, baseline_s: 92.4, extra_s_median: 41.6, kind: 'slow zone', ...patch });
export const fixtureSlowZoneRows: SlowZoneRow[] = [
  zoneRow('633S', '634S', '28 St → 23 St-Baruch College', '4 6'),
  zoneRow('419S', '420S', 'Wall St → Bowling Green', '4 5', { kind: 'disruption', start_date: '2026-08-31', baseline_s: 88, extra_s_median: 134.4, slow_days: 5 }),
  zoneRow('L02N', 'L01N', '6 Av → 8 Av', 'L', { start_date: '2026-07-13', end_date: '2026-09-02', baseline_s: 71.5, extra_s_median: 18.3, slow_days: 38 }),
  zoneRow('L03N', 'L02N', '14 St-Union Sq → 6 Av', 'L', { end_date: '2026-08-21' }),
  zoneRow('634S', '635S', '23 St-Baruch College → 14 St-Union Sq', '4 6', { kind: 'service change' }),
];

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
    service.packs = new FleetPackService(fleetFile, join(directory, 'offline-v2'), { generatedAtForTests: fixtureNow });
    await service.packs.start();
    service.slowZones.accept(fixtureSlowZoneRows, { fetchedAt: fixtureNow, timestamp: fixtureNow - 3600 });
    service.refreshBoards(fixtureNow);
    return { service, directory, selectedTripKey: selected.key, selectedCarId: 'nyct:R211A:4149', close };
  } catch (error) { await close(); throw error; }
}
