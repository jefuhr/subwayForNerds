import test from 'node:test';
import assert from 'node:assert/strict';
import { njtCatalog } from '../server/njt';
import { bundledCatalog } from '../server/catalog';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';
import rows from '../data/stations.json';

test('NJT catalogs all three light rail systems with distinct stations and usable coordinates', () => {
  assert.deepEqual(Object.fromEntries(['NJT-HBLR', 'NJT-NLR', 'NJT-RIVER'].map(route => [route, njtCatalog.filter(s => s.routes.includes(route)).length])), { 'NJT-HBLR': 24, 'NJT-NLR': 17, 'NJT-RIVER': 21 });
  assert.equal(new Set(bundledCatalog.map(s => s.id)).size, bundledCatalog.length);
  for (const s of njtCatalog) {
    assert.ok(s.lat > 39 && s.lat < 42 && s.lon > -76 && s.lon < -73);
    assert.equal(s.departureMode, 'external');
    assert.match(s.parts[0].stationId, /^\d{5}$/);
    assert.ok(s.municipality);
  }
  assert.equal(njtCatalog.find(s => s.id === 'njt-lr-30776')?.name, 'Harriet Tubman Square (NLR)');
  assert.equal(njtCatalog.find(s => s.id === 'njt-lr-30831')?.name, 'Harsimus Cove (HBLR)');
});

test('NJT station APIs remain available without upstream data and exclude MTA alerts and equipment', async () => {
  const service = new TransitService();
  service.alerts = [{ id: 'mta-wide', title: 'MTA notice', description: '', routes: [], stops: [], selectors: [], periods: [] }];
  service.equipment = [{ stationcomplexid: 'njt-lr-30771', equipmentno: 'fake' }];
  service.refreshBoards();
  const app = await createServer(service);
  try {
    for (const id of ['njt-lr-30771', 'njt-lr-30829', 'njt-lr-30855']) {
      const response = await app.inject(`/api/v1/stations/${id}/board`);
      assert.equal(response.statusCode, 200);
      const board = response.json();
      assert.equal(board.station.departureMode, 'external');
      assert.deepEqual(board.sources, []);
      assert.deepEqual(board.alerts, []);
      assert.deepEqual(board.departures, []);
      assert.deepEqual(service.context(id), { entrances: [], equipment: [], outages: [], sources: [] });
    }
    assert.equal(service.boards.get('602')!.alerts.length, 1);
  } finally { await app.close(); }
});

test('MTA catalog refresh retains NJT light rail and PATH stations', async () => {
  const socrata = rows.map(r => ({ gtfs_stop_id: r.id, station_id: r.stationId, complex_id: r.complexId, stop_name: r.name, line: r.line, daytime_routes: r.routes.join(' '), gtfs_latitude: String(r.lat), gtfs_longitude: String(r.lon), ada: r.ada, borough: r.borough }));
  const service = new TransitService({ fetcher: (async () => new Response(JSON.stringify(socrata))) as typeof fetch });
  const tasks: (() => Promise<void>)[] = [];
  service.schedule = task => { tasks.push(task); };
  service.restore = async () => undefined;
  service.persist = async () => {};
  service.startContext();
  await tasks[0]();
  assert.equal(service.catalog.filter(s => s.id.startsWith('njt-lr-')).length, 62);
  assert.equal(service.catalog.filter(s => s.id.startsWith('path-')).length, 13);
  assert.equal(service.boards.get('njt-lr-31145')!.station.name, '8th Street (HBLR)');
});
