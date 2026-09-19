import type { Station } from '../shared/types';
import { distanceMeters } from '../shared/display';

export type Coordinates = { latitude: number; longitude: number };
export function stationDistance(station: Station, coords: Coordinates) {
  const parts = station.parts.filter(p => Number.isFinite(p.lat) && Number.isFinite(p.lon));
  return Math.min(...(parts.length ? parts : [station]).map(p => distanceMeters(coords.latitude, coords.longitude, p.lat, p.lon)));
}
export function orderFavorites(favorites: string[], stations: Station[], coords?: Coordinates): Station[] {
  const catalog = new Map(stations.map(s => [s.id, s]));
  const saved = [...new Set(favorites)].map(id => catalog.get(id)).filter((s): s is Station => !!s);
  return coords ? saved.sort((a, b) => stationDistance(a, coords) - stationDistance(b, coords)) : saved;
}
export function stationPages(favorites: string[], temporary: string | null, current: string): string[] {
  return [...new Set([...(temporary && !favorites.includes(temporary) ? [temporary] : []), ...favorites, ...(!favorites.includes(current) && current !== temporary ? [current] : [])])];
}
