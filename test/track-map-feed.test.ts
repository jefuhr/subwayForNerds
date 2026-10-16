import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeFeed } from '../server/transit';

test('a vehicle with a stop sequence uses the GTFS in-transit default without borrowing its evidence clock', () => {
	const trip = { trip_id: 'default-status', start_date: '20261016', route_id: '1' };
	const raw = { header: { timestamp: 2000 }, entity: [
		{ trip_update: { trip, stop_time_update: [{ stop_id: '101N', stop_sequence: 1, arrival: { time: 2020 } }] } },
		{ vehicle: { trip, stop_id: '101N', current_stop_sequence: 1, timestamp: 1800 } },
	] };
	const train = [...normalizeFeed('gtfs', raw, []).values()][0];
	assert.equal(train.position?.status, 'IN_TRANSIT_TO');
	assert.equal(train.position?.timestamp, 1800);
	assert.equal(train.timestamp, 2000);
	delete (raw.entity[1].vehicle as any).current_stop_sequence;
	assert.equal([...normalizeFeed('gtfs', raw, []).values()][0].position?.status, undefined);
});
