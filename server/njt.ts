import rows from '../data/njt-light-rail-stations.json';
import { NJT_LINES } from '../shared/njt';
import type { Station } from '../shared/types';

// NJ TRANSIT GIS station IDs are kept separate from PATH and MTA complexes.
export const njtCatalog: Station[] = rows.map(row => {
  const id = `njt-lr-${row.code}`, line = NJT_LINES[row.route];
  const name = `${row.name} (${line.label})`, routes = [row.route];
  return { id, name, borough: 'NJ', municipality: row.municipality, routes,
    lat: row.lat, lon: row.lon, departureMode: 'external',
    parts: [{ id, stationId: row.code, name, line: `NJ Transit ${line.name}`, routes,
      lat: row.lat, lon: row.lon, ada: '', adaNotes: '', north: 'Northbound', south: 'Southbound' }] };
});
