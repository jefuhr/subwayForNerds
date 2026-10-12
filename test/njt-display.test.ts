import test from 'node:test';
import assert from 'node:assert/strict';
import { boardable, clockTime, countdown, currentVehiclePositions, freshness, vehiclePositionDisplay } from '../shared/display';
import type { VehiclePosition } from '../shared/types';

const now = Date.parse('2026-10-12T14:00:00Z') / 1000;
const position = (age: number, changes: Partial<VehiclePosition> = {}): VehiclePosition => ({
	id: 'njt-vehicle-1', provider: 'njt-bus-g2', vehicleId: '2011', route: 'NJT-HBLR',
	lat: 40.735, lon: -74.03, timestamp: now - age, fetchedAt: now, ...changes,
});

test('NJT predictions become stale after 60 seconds while the default MTA window stays 90', () => {
	assert.equal(freshness(now - 60, now, 60), 'live');
	assert.equal(freshness(now - 61, now, 60), 'stale');
	assert.equal(freshness(now - 90, now), 'live');
	assert.equal(freshness(now - 91, now), 'stale');
	assert.equal(freshness(now - 300, now, 60), 'stale');
	assert.equal(freshness(now - 301, now, 60), 'expired');
	assert.equal(freshness(null, now, 60), 'unavailable');
});

test('NJT countdowns stop counting when stale or cached and preserve existing time formats', () => {
	assert.deepEqual(countdown(now + 120, now - 60, now, false, '24h', 60), { value: '2', unit: 'min' });
	assert.deepEqual(countdown(now + 120, now - 61, now, false, '24h', 60), { value: '10:02', unit: 'last estimate' });
	assert.deepEqual(countdown(now + 120, now - 61, now), { value: '2', unit: 'min' });
	assert.deepEqual(countdown(now + 120, now, now, true, '12h', 60), { value: clockTime(now + 120), unit: 'last estimate' });
	assert.deepEqual(countdown(null, now, now, false, '12h', 60), { value: '—', unit: 'no estimate' });
});

test('GPS uses its source clock independently of fresh fetches and arrival predictions', () => {
	assert.deepEqual(vehiclePositionDisplay(position(60, { stopName: 'Hoboken Terminal' }), now), { location: 'Hoboken Terminal', age: '1m ago', lastKnown: false });
	assert.deepEqual(vehiclePositionDisplay(position(61), now), { location: '40.73500, -74.03000', age: '1m ago', lastKnown: true });
	assert.equal(vehiclePositionDisplay(position(0), now, true)?.lastKnown, true);
	assert.equal(vehiclePositionDisplay(position(300), now)?.lastKnown, true);
	assert.equal(vehiclePositionDisplay(position(301), now), null);
	assert.equal(vehiclePositionDisplay(undefined, now), null);
});

test('GPS without a reported stop name uses actual coordinates without inferring a boarding stop', () => {
	assert.equal(vehiclePositionDisplay(position(10, { stopId: '30829' }), now)?.location, '40.73500, -74.03000');
	assert.equal(vehiclePositionDisplay(position(10, { stopName: '  ' }), now)?.location, '40.73500, -74.03000');
	for (const changes of [{ lat: NaN }, { lon: Infinity }, { lat: 91 }, { lon: -181 }, { timestamp: 0 }, { timestamp: NaN }, { timestamp: now + 61 }, { lat: 0, lon: 0 }]) {
		assert.equal(vehiclePositionDisplay(position(10, changes), now), null);
	}
});

test('current GPS list contains only this light rail system and expires reports after 300 seconds', () => {
	const current = position(10), old = position(300, { id: 'old' });
	const positions = [current, old, position(301, { id: 'expired' }), position(5, { route: 'NJT-NLR' }), position(10, { lat: NaN })];
	assert.deepEqual(currentVehiclePositions(positions, ['NJT-HBLR'], now), [current, old]);
	assert.deepEqual(currentVehiclePositions(undefined, ['NJT-HBLR'], now), []);
});

test('NO_DATA never establishes a boardable arrival', () => {
	assert.equal(boardable({ relationship: 'NO_DATA' } as any), false);
});
