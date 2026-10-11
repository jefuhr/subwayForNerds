import test from 'node:test';
import assert from 'node:assert/strict';
import { consistCarIDs, consistKey, favoriteTrainMatch, fleetCarID } from '../shared/favorites';
import { defaults } from '../shared/settings';
import type { Consist } from '../shared/types';

const now = 20000;
const consist = (numbers = ['001', '002'], type = 'R160A'): Consist => ({ cars: numbers.map(number => ({ number, type })), updatedAt: now, fetchedAt: now, source: 'helium' });

test('car identity preserves namespace, equipment family and leading zeroes', () => {
	assert.equal(fleetCarID('001', 'R160B', 'gtfs'), 'nyct:R160:001');
	assert.equal(fleetCarID('001', 'R160', 'gtfs-si'), 'sir:R160:001');
	assert.notEqual(fleetCarID('001', 'R46', 'gtfs'), fleetCarID('001', 'R160', 'gtfs'));
	assert.equal(fleetCarID('001', undefined, 'gtfs'), undefined);
	assert.equal(fleetCarID('1:2', 'R160', 'gtfs'), undefined);
	assert.equal(fleetCarID('001', 'R160\n', 'gtfs'), undefined);
	assert.equal(consistCarIDs(consist(['001', '001']), 'gtfs'), undefined);
	assert.equal(consistCarIDs(consist([]), 'gtfs'), undefined);
});

test('exact favorites match complete membership independent of order', () => {
	const favorites = defaults().trainFavorites;
	favorites.consists = [consistCarIDs(consist(), 'gtfs')!];
	assert.equal(consistKey([...favorites.consists[0]].reverse()), consistKey(favorites.consists[0]));
	assert.deepEqual(favoriteTrainMatch(consist(['002', '001']), 'gtfs', favorites, now), { carIDs: favorites.consists[0], exactConsist: true });
	assert.equal(favoriteTrainMatch(consist(['001']), 'gtfs', favorites, now), null);
	assert.equal(favoriteTrainMatch(consist(['001', '002', '003']), 'gtfs', favorites, now), null);
	assert.equal(favoriteTrainMatch(consist(), 'gtfs-si', favorites, now), null);
	assert.equal(favoriteTrainMatch(consist(undefined, 'R46'), 'gtfs', favorites, now), null);
});

test('individual cars and any-car matching identify only the saved members', () => {
	const favorites = defaults().trainFavorites;
	favorites.cars = ['nyct:R160:003'];
	favorites.consists = [['nyct:R160:001', 'nyct:R160:002']];
	assert.deepEqual(favoriteTrainMatch(consist(['003', '004']), 'gtfs', favorites, now), { carIDs: ['nyct:R160:003'], exactConsist: false });
	favorites.match = 'anyCar';
	assert.deepEqual(favoriteTrainMatch(consist(['001', '003', '004']), 'gtfs', favorites, now), { carIDs: ['nyct:R160:001', 'nyct:R160:003'], exactConsist: false });
	assert.deepEqual(favorites.consists, [['nyct:R160:001', 'nyct:R160:002']]);
});

test('stale, cached, malformed and unknown equipment never produces a favorite match', () => {
	const favorites = defaults().trainFavorites; favorites.cars = ['nyct:R160:001'];
	for (const value of [undefined, { ...consist(), updatedAt: now - 301 }, { ...consist(), fetchedAt: now - 301 }, { ...consist(), updatedAt: now + 61 }, { ...consist(), cars: [{ number: '001' }] }, consist(['001', '001'])]) {
		assert.equal(favoriteTrainMatch(value, 'gtfs', favorites, now), null);
	}
	assert.equal(favoriteTrainMatch(consist(), 'gtfs', favorites, now, true), null);
});
