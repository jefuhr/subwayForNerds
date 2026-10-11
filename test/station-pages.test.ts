import test from 'node:test';
import assert from 'node:assert/strict';
import type { Station } from '../shared/types';
import { orderFavorites, stationDistance, stationPages } from '../src/stationPages';
const station = (id: string, lat: number, partLat?: number): Station => ({ id, name: id, lat, lon: 0, borough: 'M', routes: [], parts: partLat == null ? [] : [{ id, stationId: id, name: id, lat: partLat, lon: 0, line: '', routes: [], ada: '', adaNotes: '', north: '', south: '' }] });
test('favorite order uses closest part, coordinate fallback, stable ties and available catalog entries', () => {
  const stations = [station('a', 10, 1), station('b', 2), station('c', 1)];
  const saved = ['missing', 'b', 'c', 'a', 'a'];
  assert.deepEqual(orderFavorites(saved, stations).map(s => s.id), ['b', 'c', 'a']);
  assert.deepEqual(orderFavorites(saved, stations, { latitude: 0, longitude: 0 }).map(s => s.id), ['c', 'a', 'b']);
  assert.equal(stationDistance(stations[0], { latitude: 1, longitude: 0 }), 0);
  assert.deepEqual(saved, ['missing', 'b', 'c', 'a', 'a']);
});
test('temporary pages stay first, disappear when favorited, and keep an unavailable current station accessible', () => {
  assert.deepEqual(stationPages(['a', 'b'], 'x', 'b'), ['x', 'a', 'b']);
  assert.deepEqual(stationPages(['a', 'x', 'b'], 'x', 'x'), ['a', 'x', 'b']);
  assert.deepEqual(stationPages([], 'x', 'x'), ['x']);
  assert.deepEqual(stationPages([], null, 'unknown'), ['unknown']);
});
