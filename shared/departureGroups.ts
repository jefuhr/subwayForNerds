import type { Departure, Station } from './types';

export const departureViews = [
  { id: 'track', short: 'Track', label: 'By track' },
  { id: 'direction', short: 'Direction', label: 'By direction · all platforms' },
  { id: 'family', short: 'Families', label: 'By direction · route families' },
  { id: 'corridor', short: 'Corridors', label: 'By direction · station corridors' },
  { id: 'service', short: 'Service', label: 'By service' },
] as const;
export type DepartureView = typeof departureViews[number]['id'];
export const validView = (value: unknown): DepartureView => departureViews.some(v => v.id === value) ? value as DepartureView : 'track';
export const directionLabel = (direction: string) => direction === 'NORTH' ? 'Northbound' : direction === 'SOUTH' ? 'Southbound' : 'Direction unknown';
const directionKey = (d: Departure) => ['NORTH', 'SOUTH'].includes(d.direction) ? d.direction : 'UNKNOWN';
const natural = (a: string, b: string) => a.localeCompare(b, 'en', { numeric: true });
const directionOrder = (direction: string) => ['NORTH', 'SOUTH', 'UNKNOWN'].indexOf(direction);
export function routeFamily(route: string) {
  if (/^[123]$/.test(route)) return '1 / 2 / 3';
  if (/^[456]X?$/.test(route)) return '4 / 5 / 6';
  if (/^7X?$/.test(route)) return '7';
  if (/^[ACE]$/.test(route)) return 'A / C / E';
  if (/^(B|D|F|FX|M)$/.test(route)) return 'B / D / F / M';
  if (/^[NQRW]$/.test(route)) return 'N / Q / R / W';
  if (/^[JZ]$/.test(route)) return 'J / Z';
  return ({ GS: '42 St Shuttle', FS: 'Franklin Shuttle', H: 'Rockaway Shuttle', SI: 'SIR' } as Record<string, string>)[route] || route;
}
export interface DepartureGroup {
  key: string; direction: string; label: string; service?: string; departures: Departure[];
}
export function groupDepartures(departures: Departure[], station: Station, view: DepartureView): DepartureGroup[] {
  const groups = new Map<string, DepartureGroup>();
  for (const d of departures) {
    const direction = directionKey(d), part = station.parts.find(p => p.id === d.partId);
    const label = view === 'family' ? routeFamily(d.route) : view === 'corridor' ? part?.line || d.partId : view === 'service' ? d.route : '';
    const identity = view === 'track' ? [d.partId, d.actualTrack || d.scheduledTrack || '?'] : view === 'corridor' ? [d.partId] : [label];
    const key = JSON.stringify([view, direction, ...identity]);
    const group = groups.get(key) || { key, direction, label, ...(view === 'service' ? { service: d.route } : {}), departures: [] };
    group.departures.push(d); groups.set(key, group);
  }
  for (const group of groups.values()) group.departures.sort((a, b) => (a.time ?? Infinity) - (b.time ?? Infinity) || a.key.localeCompare(b.key));
  return [...groups.values()].sort((a, b) => {
    if (view === 'service') return natural(a.label, b.label) || directionOrder(a.direction) - directionOrder(b.direction);
    if (view === 'track') {
      const x = a.departures[0], y = b.departures[0];
      return x.direction.localeCompare(y.direction) || x.partId.localeCompare(y.partId) || (x.actualTrack || x.scheduledTrack || '').localeCompare(y.actualTrack || y.scheduledTrack || '');
    }
    return directionOrder(a.direction) - directionOrder(b.direction) || natural(a.label, b.label) || a.key.localeCompare(b.key);
  });
}
