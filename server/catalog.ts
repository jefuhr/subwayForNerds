import rows from '../data/stations.json';
import type { Station, StationPart } from '../shared/types';

export type CatalogRow = StationPart & { complexId: string; borough: string };
export function makeCatalog(records: CatalogRow[]): Station[] {
  const groups = new Map<string, Station>();
  for (const row of records) {
    let station = groups.get(row.complexId);
    if (!station) {
      station = { id: row.complexId, name: row.name, borough: row.borough, routes: [], lat: row.lat, lon: row.lon, parts: [] };
      groups.set(row.complexId, station);
    }
    station.parts.push(row);
    station.routes = [...new Set([...station.routes, ...row.routes])].sort();
    if (!station.name.split(' / ').includes(row.name)) station.name += ` / ${row.name}`;
  }
  return [...groups.values()].sort((a, b) => a.name.localeCompare(b.name));
}
export const bundledCatalog = makeCatalog(rows);
export function fromSocrata(r: Record<string, string>): CatalogRow {
  return { id: r.gtfs_stop_id, stationId: r.station_id, complexId: r.complex_id,
    name: r.stop_name, line: r.line, routes: r.daytime_routes.split(' '), lat: +r.gtfs_latitude,
    lon: +r.gtfs_longitude, ada: r.ada, adaNotes: r.ada_direction_notes || '',
    north: r.north_direction_label || 'Northbound', south: r.south_direction_label || 'Southbound', borough: r.borough };
}
export const parentStop = (id: string) => id.replace(/[NS]$/, '');
