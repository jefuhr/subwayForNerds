import type { Board, Train, VehiclePosition } from '../shared/types';
import type { TransitService } from '../server/service';
import { fixtureNow as now } from './fixture-service';

/** Synthetic normalized contracts for simulator acceptance, never live provider data. */
export function installNjtUIFixture(service: TransitService) {
	service.catalog = service.catalog.map(station => {
		if (!station.id.startsWith('njt-lr-')) return station;
		const { departureMode: _external, ...connected } = station;
		return connected;
	});
	for (const [id, destination, hasPrediction] of [
		['njt-lr-30829', 'Tonnelle Avenue', true],
		['njt-lr-30771', 'Grove Street', false],
		['njt-lr-30855', 'Camden', true],
	] as const) {
		const station = service.catalog.find(station => station.id === id)!;
		const route = station.routes[0], part = station.parts[0];
		const predictions = { id: 'njt-bus-g2-predictions', timestamp: now, fetchedAt: now, error: null, staleAfter: 60 };
		const positions = { ...predictions, id: 'njt-bus-g2-positions' };
		const gps: VehiclePosition = {
			id: `njt-bus-g2|${route}|fixture`, provider: 'njt-bus-g2', vehicleId: 'fixture', route,
			lat: station.lat, lon: station.lon, timestamp: now - 61, fetchedAt: now,
		};
		const train: Train = {
			key: `njt-ui-${id}`, feed: predictions.id, tripId: id, route, destination, direction: 'NORTH',
			timestamp: now, staleAfter: 60, stops: [{ id: part.stationId, stationId: station.id, name: station.name, sequence: 1, arrival: now + 180, departure: now + 190 }], alerts: [],
		};
		const board: Board = {
			station, generatedAt: now, sources: [predictions, positions], alerts: [],
			njt: { configured: true, predictions, positions, cacheError: null },
			vehiclePositions: route === 'NJT-RIVER' ? [] : [gps],
			departures: hasPrediction ? [{
				key: train.key, tripKey: train.key, route, destination, direction: train.direction,
				stopId: part.stationId, partId: part.id, area: part.line, time: now + 190,
				arrival: now + 180, departure: now + 190, pattern: part.line, patternSource: 'static',
				location: 'Position unavailable', stopsAway: null, feed: predictions.id, timestamp: now, staleAfter: 60, alerts: [], onward: [],
			}] : [],
		};
		service.boards.set(station.id, board);
		if (hasPrediction) service.details.set(train.key, { train, raw: null, source: { state: predictions, header: { timestamp: now } } });
	}
}
