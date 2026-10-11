import { distanceMeters } from './display';
import type { StationSelection } from './settings';
import type { Station } from './types';

export type StationLocation = { latitude: number; longitude: number; timestamp: number };
export const favoriteInsideRadius = (distance: number, radiusFeet: number) => Number.isFinite(distance) && distance >= 0 && distance < radiusFeet * 0.3048;
const validCoordinate = (lat: number, lon: number) => Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180;
export const usableStationLocation = (location: StationLocation | undefined, now: number): location is StationLocation => !!location && validCoordinate(location.latitude, location.longitude) && Number.isFinite(location.timestamp) && location.timestamp > 0 && location.timestamp <= now && now - location.timestamp < 300;
export function stationDistanceMeters(station: Station, location: StationLocation): number {
	const parts = station.parts.filter(part => validCoordinate(part.lat, part.lon));
	const points = parts.length ? parts : [station];
	return Math.min(...points.filter(point => validCoordinate(point.lat, point.lon)).map(point => distanceMeters(location.latitude, location.longitude, point.lat, point.lon)));
}
/** Widgets may fall back without GPS; app callers preserve their explicit navigation. */
export function selectStationAutomatically(stations: readonly Station[], favorites: readonly string[], selection: StationSelection, location: StationLocation | undefined, previous?: string, now = Date.now() / 1000): Station | undefined {
	const favoriteStations = favorites.map(id => stations.find(station => station.id === id)).filter((station): station is Station => !!station);
	const candidates = selection.mode === 'favorite' ? favoriteStations : stations;
	const fallback = () => candidates.find(station => station.id === previous) ?? favoriteStations[0] ?? candidates[0];
	if (!candidates.length) return;
	if (!usableStationLocation(location, now)) return fallback();
	const nearest = (options: readonly Station[]) => options.map(station => ({ station, distance: stationDistanceMeters(station, location) })).filter(item => Number.isFinite(item.distance)).sort((a, b) => a.distance - b.distance || (a.station.id < b.station.id ? -1 : a.station.id > b.station.id ? 1 : 0))[0];
	if (selection.mode === 'nearbyFavorite') {
		const favorite = nearest(favoriteStations);
		if (favorite && favoriteInsideRadius(favorite.distance, selection.radiusFeet)) return favorite.station;
	}
	return nearest(candidates)?.station ?? fallback();
}
