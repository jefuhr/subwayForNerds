import stations from '../data/path-stations.json';
import { PATH_ROUTES } from '../shared/path';
import type { Station, Train } from '../shared/types';

export const PATH_URL = 'https://www.panynj.gov/bin/portauthority/ridepath.json';
// Lowercase IDs avoid the subway parser's N/S platform suffix convention.
export const pathId = (code: string) => `path-${code.toLowerCase()}`;
export const pathCatalog: Station[] = stations.map(s => {
  const id = pathId(s.code), name = `${s.name} (PATH)`;
  const routes = Object.entries(PATH_ROUTES).filter(([, r]) => r.stops.includes(s.code)).map(([id]) => id);
  return { id, name, routes, borough: ['CHR', '09S', '14S', '23S', '33S', 'WTC'].includes(s.code) ? 'M' : 'NJ', lat: s.lat, lon: s.lon,
    parts: [{ id, stationId: id, name, routes, line: 'PATH', lat: s.lat, lon: s.lon, ada: '', adaNotes: '', north: 'To New York', south: 'To New Jersey' }] };
});
const colorRoutes: Record<string, string> = { D93A30: 'PATH-NWK-WTC', '65C100': 'PATH-HOB-WTC', FF9900: 'PATH-JSQ-33', '4D92FB': 'PATH-HOB-33', '4D92FB,FF9900': 'PATH-JSQ-33-HOB' };

export function normalizePath(raw: any): Map<string, Train> {
  if (!Array.isArray(raw?.results) || !raw.results.length) throw new Error('Invalid PATH response');
  const trains = new Map<string, Train>();
  for (const result of raw.results) {
    const station = pathCatalog.find(s => s.id === pathId(String(result.consideredStation)));
    if (!station) continue;
    if (!Array.isArray(result.destinations)) throw new Error('Invalid PATH destinations');
    for (const destination of result.destinations) {
      if (!Array.isArray(destination.messages)) throw new Error('Invalid PATH messages');
      for (const [index, message] of destination.messages.entries()) {
        const timestamp = Math.floor(Date.parse(message.lastUpdated) / 1000);
        if (!Number.isFinite(timestamp) || timestamp <= 0) throw new Error('Invalid PATH timestamp');
        const color = String(message.lineColor).toUpperCase().replace(/[#\s]/g, '').split(',').sort().join(',');
        const route = colorRoutes[color] || 'PATH';
        const seconds = /^\d+$/.test(String(message.secondsToArrival)) ? Number(message.secondsToArrival) : null;
        const time = seconds == null ? null : timestamp + seconds;
        // The source reports independent station estimates, not linked train journeys.
        const tripId = `${station.id}-${destination.label}-${message.target}-${index}`;
        const key = `path|unknown|${tripId}|`;
        trains.set(key, { key, tripId, feed: 'path', route, timestamp,
          destination: message.headSign || stations.find(s => s.code === message.target)?.name || 'Destination unavailable',
          direction: String(destination.label).toUpperCase() === 'TONY' ? 'TO_NY' : String(destination.label).toUpperCase() === 'TONJ' ? 'TO_NJ' : 'UNKNOWN',
          stops: [{ id: station.id, stationId: station.id, name: station.name, arrival: time, departure: null }],
          alerts: ['PATH provides station arrival estimates; train positions, tracks and onward predictions are unavailable.'] });
      }
    }
  }
  return trains;
}
