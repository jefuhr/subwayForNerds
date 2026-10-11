import test from 'node:test';
import assert from 'node:assert/strict';
import { favoriteInsideRadius, selectStationAutomatically } from '../shared/station-selection';
import type { Station } from '../shared/types';

const now = 20000;
const location = { latitude: 0, longitude: 0, timestamp: now };
const station = (id: string, lat: number): Station => ({ id, name: id, lat, lon: 0, borough: '', routes: [], parts: [] });
const catalog = [station('favorite', 0.01), station('closest', 0.001)];

test('automatic selection chooses closest favorite, closest station or a favorite inside the radius', () => {
	const choose = (mode: 'favorite' | 'closest' | 'nearbyFavorite', radiusFeet = 5280) => selectStationAutomatically(catalog, ['favorite'], { mode, radiusFeet }, location, undefined, now)?.id;
	assert.equal(choose('favorite'), 'favorite');
	assert.equal(choose('closest'), 'closest');
	assert.equal(choose('nearbyFavorite'), 'favorite');
	assert.equal(choose('nearbyFavorite', 1), 'closest');
	assert.equal(favoriteInsideRadius(0.3048, 1), false);
	assert.equal(favoriteInsideRadius(0.3047, 1), true);
	assert.equal(favoriteInsideRadius(1609.344, 5280), false);
	assert.equal(favoriteInsideRadius(1609.343, 5280), true);
});

test('nearest station part and deterministic station ID ties drive distance selection', () => {
	const complex = station('complex', 1);
	complex.parts = [{ ...station('entrance', 0.0001), stationId: 'complex', line: '', ada: '', adaNotes: '', north: '', south: '' }];
	assert.equal(selectStationAutomatically([...catalog, complex], [], { mode: 'closest', radiusFeet: 1 }, location, undefined, now)?.id, 'complex');
	assert.equal(selectStationAutomatically([station('b', 0.01), station('a', 0.01)], [], { mode: 'closest', radiusFeet: 1 }, location, undefined, now)?.id, 'a');
});

test('empty favorites, missing references and unusable locations have deterministic fallbacks', () => {
	const closest = { mode: 'closest' as const, radiusFeet: 5280 };
	assert.equal(selectStationAutomatically(catalog, [], closest, location, undefined, now)?.id, 'closest');
	assert.equal(selectStationAutomatically(catalog, ['missing'], { ...closest, mode: 'nearbyFavorite' }, location, undefined, now)?.id, 'closest');
	assert.equal(selectStationAutomatically(catalog, [], { ...closest, mode: 'favorite' }, location, undefined, now), undefined);
	for (const value of [undefined, { ...location, timestamp: now - 300 }, { ...location, timestamp: now + 1 }, { ...location, latitude: NaN }, { ...location, longitude: 181 }]) {
		assert.equal(selectStationAutomatically(catalog, ['favorite'], closest, value, 'closest', now)?.id, 'closest');
	}
	assert.equal(selectStationAutomatically([], [], closest, location, undefined, now), undefined);
});
