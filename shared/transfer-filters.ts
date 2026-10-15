import type { Settings, StationSettings, TransferStationSettings } from './settings';
import type { Station } from './types';

/** Per-station filter keys: the aliases station boards store and show. */
export const routeFilterKey = (route: string): string => ({ GS: 'S', FS: 'S', H: 'S', SI: 'SIR' } as Record<string, string>)[route] || route;
/** Global exclusions also fold express variants into their line, matching native LineVisibility. */
export const lineVisibilityKey = (route: string): string => ({ '4X': '4', '5X': '5', '6X': '6', '7X': '7', FX: 'F', GS: 'S', FS: 'S', H: 'S', SI: 'SIR' } as Record<string, string>)[route] || route;
export const lineVisible = (route: string, hiddenRoutes: string[]): boolean => !hiddenRoutes.some(hidden => lineVisibilityKey(hidden) === lineVisibilityKey(route));
const normalizeRoutes = (routes: string[]) => [...new Set(routes.map(routeFilterKey))].sort();
const boardFilter = (settings: Settings, stationId: string): TransferStationSettings => {
	const { direction, routes } = settings.stations[stationId] || { direction: 'ALL', routes: [] };
	return { direction, routes };
};

/** The filter that applies to transfers at a target station, keyed by that station's ID. */
export function transferFilter(settings: Settings, stationId: string): TransferStationSettings {
	const separate = settings.transfers.separateFilters ? settings.transfers.stations[stationId] : undefined;
	return structuredClone(separate || boardFilter(settings, stationId));
}

/** Separate mode copies the station's board filter on first use so later board edits do not leak in. */
export function seedTransferFilter(settings: Settings, stationId: string): Settings {
	if (!settings.transfers.separateFilters || settings.transfers.stations[stationId]) return settings;
	return { ...settings, transfers: { ...settings.transfers, stations: { ...settings.transfers.stations, [stationId]: boardFilter(settings, stationId) } } };
}

export function withTransferFilter(settings: Settings, stationId: string, patch: Partial<TransferStationSettings>): Settings {
	const next = { ...transferFilter(settings, stationId), ...patch };
	next.routes = normalizeRoutes(next.routes);
	if (settings.transfers.separateFilters) return { ...settings, transfers: { ...settings.transfers, stations: { ...settings.transfers.stations, [stationId]: next } } };
	// Shared mode edits the station board filter and keeps its grouping view.
	const board: StationSettings = { ...(settings.stations[stationId] || { direction: 'ALL', routes: [], view: 'track' }), ...next };
	return { ...settings, stations: { ...settings.stations, [stationId]: board } };
}

/** Station metadata first, then lines only seen in connections, so choices do not reshuffle as rows refresh. */
export function transferRouteChoices(station: Pick<Station, 'routes'> | undefined, connections: { route: string }[], hiddenRoutes: string[]): string[] {
	return [...new Set([...(station?.routes || []), ...connections.map(c => c.route)].map(routeFilterKey))].filter(route => lineVisible(route, hiddenRoutes));
}

export function filterTransfers<T extends { route: string; direction: string }>(connections: T[], filter: TransferStationSettings, hiddenRoutes: string[]): T[] {
	const routes = normalizeRoutes(filter.routes);
	return connections.filter(c => lineVisible(c.route, hiddenRoutes) && (filter.direction === 'ALL' || c.direction === filter.direction) && (!routes.length || routes.includes(routeFilterKey(c.route))));
}
