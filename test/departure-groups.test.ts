import test from 'node:test';
import assert from 'node:assert/strict';
import { groupDepartures, routeFamily, validView } from '../shared/departureGroups';
import { bundledCatalog } from '../server/catalog';
import type { Departure } from '../shared/types';
const station = bundledCatalog.find(s => s.id === '617')!;
const make = (key: string, route: string, partId: string, direction: string, time: number | null, actualTrack?: string) => ({ key, route, partId, direction, time, actualTrack } as Departure);
const rows = [make('d', 'D', 'R31', 'NORTH', 200, '1'), make('n', 'N', 'R31', 'NORTH', 100, '3'), make('b', 'B', 'D24', 'NORTH', 300), make('q', 'Q', 'D24', 'NORTH', null), make('s', 'N', 'R31', 'SOUTH', 100, '2')];
test('five views preserve every departure and distinguish corridors from route families', () => {
  for (const view of ['track', 'direction', 'family', 'corridor', 'service'] as const) {
    const groups = groupDepartures(rows, station, view);
    assert.deepEqual(groups.flatMap(g => g.departures.map(d => d.key)).sort(), rows.map(d => d.key).sort());
  }
  assert.equal(groupDepartures(rows, station, 'track').length, 4);
  const directions = groupDepartures(rows, station, 'direction');
  assert.deepEqual(directions.map(g => g.direction), ['NORTH', 'SOUTH']);
  assert.deepEqual(directions[0].departures.map(d => d.key), ['n', 'd', 'b', 'q']);
  const families = groupDepartures(rows, station, 'family');
  assert.deepEqual(families.find(g => g.label === 'B / D / F / M')!.departures.map(d => d.route), ['D', 'B']);
  const corridors = groupDepartures(rows, station, 'corridor');
  assert.deepEqual(corridors.find(g => g.label === '4th Av' && g.direction === 'NORTH')!.departures.map(d => d.route), ['N', 'D']);
  assert.deepEqual(groupDepartures(rows, station, 'service').filter(g => g.service === 'N').map(g => g.direction), ['NORTH', 'SOUTH']);
});
test('unknown direction and tracks, scheduled fallback, ties and missing estimates stay deterministic', () => {
  const data = [make('z', 'L', 'missing', 'OTHER', null), make('b', 'L', 'missing', 'NORTH', 100), make('a', 'L', 'missing', 'NORTH', 100)];
  const groups = groupDepartures(data, station, 'direction');
  assert.deepEqual(groups.map(g => g.direction), ['NORTH', 'UNKNOWN']);
  assert.deepEqual(groups[0].departures.map(d => d.key), ['a', 'b']);
  assert.deepEqual(data.map(d => d.key), ['z', 'b', 'a']);
  const scheduled = { ...data[1], scheduledTrack: '2' };
  assert.equal(groupDepartures([scheduled, { ...scheduled, key: 'reported', actualTrack: '2' }], station, 'track').length, 1);
  assert.equal(groupDepartures([scheduled, { ...scheduled, key: 'changed', actualTrack: '3' }], station, 'track').length, 2);
});
test('shuttles remain distinct services and express variants have the right family', () => {
  const shuttles = ['GS', 'FS', 'H'].map(route => make(route, route, 'R31', 'NORTH', 100));
  assert.equal(groupDepartures(shuttles, station, 'service').length, 3);
  assert.equal(groupDepartures(shuttles, station, 'family').length, 3);
  assert.equal(routeFamily('FX'), routeFamily('F'));
  assert.equal(routeFamily('6X'), routeFamily('6'));
  assert.equal(routeFamily('7X'), routeFamily('7'));
  assert.equal(validView('bogus'), 'track'); assert.equal(validView(undefined), 'track');
  assert.equal(validView('corridor'), 'corridor');
});
