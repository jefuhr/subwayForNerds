// Normalized contract fixtures are generated solely from recorded/synthetic inputs.
// Default generation updates both backend fixtures and Swift package resources.
// An explicit destination writes only there, for isolated inspection/validation.
// Usage: npx tsx scripts/export-native-fixtures.ts [destination-directory]
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createFixtureService, fixtureNow } from '../test/fixture-service';
import { createServer } from '../server/index';
import { TransitService } from '../server/service';
import { transfers } from '../server/transfers';

export async function nativeFixtures(): Promise<Record<string, unknown>> {
  const originalNow = Date.now, originalBase = process.env.APP_BASE;
  Date.now = () => fixtureNow * 1000;
  process.env.APP_BASE = '/subwaysForNerds/';
  let fixture: Awaited<ReturnType<typeof createFixtureService>> | undefined;
  let app: Awaited<ReturnType<typeof createServer>> | undefined;
  let edgeApp: Awaited<ReturnType<typeof createServer>> | undefined;
  try {
    fixture = await createFixtureService();
    const { service } = fixture;
    app = await createServer(service);
    const get = async (path: string) => {
      const response = await app!.inject('/subwaysForNerds/api/v1/' + path);
      if (response.statusCode !== 200) throw new Error(`Fixture endpoint ${path}: HTTP ${response.statusCode}`);
      return response.json();
    };
    const selected = service.details.get(fixture.selectedTripKey)!.train;
    const stop = selected.stops.find(stop => transfers(selected, service.boards, stop.id, stop.sequence, fixtureNow).connections.length > 0);
    if (!stop) throw new Error('Recorded fixture train has no future connecting departure');
    const transferQuery = new URLSearchParams({ key: selected.key, stopId: stop.id, ...(stop.sequence == null ? {} : { sequence: String(stop.sequence) }) });
    // Published-style context records are synthetic; browser fixtures intentionally
    // retain their original unavailable-context scenario.
    service.entrances = [{ complex_id: '602', constituent_station_name: '14 St-Union Sq', entrance_type: 'Stair', entry_allowed: 'YES', exit_allowed: 'YES', entrance_latitude: '40.7357', entrance_longitude: '-73.9906' }];
    service.equipment = [{ stationcomplexid: '602', equipmentno: 'EL-fixture-1', shortdescription: 'Fixture elevator', serving: 'Street to mezzanine', isactive: 'Y', alternativeroute: 'Use the published accessible travel alternative.' }];
    service.outages = [{ equipment: 'EL-fixture-1', reason: 'Synthetic maintenance fixture', isupcomingoutage: 'N', outagedate: '09/05/2026 08:00 PM', estimatedreturntoservice: '09/06/2026 06:00 AM' }];
    for (const id of ['entrances', 'equipment', 'outages']) service.contextStates.set(id, { id, timestamp: fixtureNow, fetchedAt: fixtureNow, error: null });
    const result: Record<string, unknown> = {
      'catalog.json': await get('stations'),
      'board.json': await get('stations/602/board'),
      'trip.json': await get('trips?' + new URLSearchParams({ key: selected.key })),
      'transfers.json': await get('trips/transfers?' + transferQuery),
      'context.json': await get('stations/602/context'),
      'fleet-page.json': await get('fleet?view=cars&page=1'),
      'fleet-detail.json': await get('fleet/cars/' + encodeURIComponent(fixture.selectedCarId)),
      'offline-manifest.json': await get('fleet/offline/manifest'),
    };
    const edge = new TransitService();
    const trip = { trip_id: 'fixture|repeated /?=#', route_id: '4', start_date: '20260905', start_time: '25:00:00',
      '.transit_realtime.nyct_trip_descriptor': { train_id: 'fixture false', is_assigned: false, direction: 'NORTH' } };
    edge.accept('gtfs', { header: { timestamp: fixtureNow }, entity: [
      { id: 'edge-trip', trip_update: { trip, stop_time_update: [
        { stop_id: '635N', stop_sequence: 0, arrival: { time: 0 } },
        { stop_id: '635N', stop_sequence: 1, arrival: { time: fixtureNow + 60 }, departure: { time: fixtureNow + 70 }, '.transit_realtime.nyct_stop_time_update': { scheduled_track: '0', actual_track: '4' } },
        { stop_id: '631N', stop_sequence: 2, schedule_relationship: 'SKIPPED' },
        { stop_id: '635N', stop_sequence: 3, arrival: { time: fixtureNow + 600 }, departure: { time: fixtureNow + 610 } },
        { stop_id: 'unknownN', stop_sequence: 4 },
      ] } },
      { id: 'edge-vehicle', vehicle: { trip, stop_id: '635N', timestamp: 0, current_status: 0 } },
      { id: 'edge-missing', trip_update: { trip: { trip_id: 'fixture absent', route_id: '4', start_date: '20260905' }, stop_time_update: [{ stop_id: '635N', departure: { time: fixtureNow + 120 } }] } },
    ] }, fixtureNow);
    edgeApp = await createServer(edge);
    const edgeTrain = [...edge.details.values()].find(detail => detail.train.assigned === false)!.train;
    result['edge-board.json'] = (await edgeApp.inject('/subwaysForNerds/api/v1/stations/602/board')).json();
    result['edge-trip.json'] = (await edgeApp.inject('/subwaysForNerds/api/v1/trips?' + new URLSearchParams({ key: edgeTrain.key }))).json();
    return result;
  } finally {
    await edgeApp?.close();
    await app?.close();
    await fixture?.close();
    Date.now = originalNow;
    if (originalBase == null) delete process.env.APP_BASE; else process.env.APP_BASE = originalBase;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const destinations = process.argv[2] ? [resolve(process.argv[2])] : [
    fileURLToPath(new URL('../test/fixtures/native/', import.meta.url)),
    fileURLToPath(new URL('../ios/TransitCore/Tests/TransitCoreTests/Fixtures/', import.meta.url)),
  ];
  const fixtures = await nativeFixtures();
  for (const destination of destinations) {
    await mkdir(destination, { recursive: true });
    for (const [name, value] of Object.entries(fixtures)) await writeFile(resolve(destination, name), JSON.stringify(value, null, 2) + '\n');
    console.log(`Exported ${Object.keys(fixtures).length} native contract fixtures to ${destination}`);
  }
}
