import type { Board, Departure, ServiceAlert, SourceState, Station, Train } from '../shared/types';
import { extension } from './decode';
import { parentStop } from './catalog';
import corridorDefinitions from '../data/corridors.json';

export const FEED_ROUTES: Record<string, string[]> = {
  gtfs: ['1','2','3','4','5','6','6X','7','7X','GS'], 'gtfs-ace': ['A','C','E','H'],
  'gtfs-bdfm': ['B','D','F','FX','M','FS'], 'gtfs-g': ['G'], 'gtfs-jz': ['J','Z'],
  'gtfs-l': ['L'], 'gtfs-nqrw': ['N','Q','R','W'], 'gtfs-si': ['SI'],
};
export const nowSeconds = () => Math.floor(Date.now() / 1000);
const number = (value: unknown): number | null => value == null ? null : Number(value);
export const tripKey = (feed: string, trip: any) => [feed, trip.start_date || 'unknown', trip.trip_id, trip.start_time || ''].join('|');
const english = (value: any) => (value?.translation?.find((t: any) => t.language === 'en') || value?.translation?.[0])?.text || '';

export function normalizeFeed(feed: string, raw: any, catalog: Station[]): Map<string, Train> {
  const timestamp = number(raw.header?.timestamp) || 0;
  const stops = new Map(catalog.flatMap(s => s.parts.map(p => [p.id, { name: p.name, stationId: s.id }] as const)));
  const vehicles = new Map<string, any>();
  for (const e of raw.entity || []) if (e.vehicle?.trip) vehicles.set(tripKey(feed, e.vehicle.trip), e.vehicle);
  const trains = new Map<string, Train>();
  for (const e of raw.entity || []) {
    const update = e.trip_update;
    if (!update?.trip?.trip_id || e.is_deleted) continue;
    const descriptor = update.trip, key = tripKey(feed, descriptor), ext = extension(descriptor, 'nyct_trip_descriptor');
    const vehicle = vehicles.get(key);
    const predictions = (update.stop_time_update || []).map((s: any) => {
      const track = extension(s, 'nyct_stop_time_update');
      const known = stops.get(parentStop(s.stop_id || ''));
      return { id: s.stop_id || '', name: known?.name || s.stop_id || 'Unknown stop', stationId: known?.stationId,
        arrival: number(s.arrival?.time), departure: number(s.departure?.time),
        ...(track.scheduled_track ? { scheduledTrack: track.scheduled_track } : {}),
        ...(track.actual_track ? { actualTrack: track.actual_track } : {}),
        ...(s.schedule_relationship ? { relationship: s.schedule_relationship } : {}) };
    });
    const train: Train = { key, feed, tripId: descriptor.trip_id, serviceDate: descriptor.start_date,
      route: descriptor.route_id || '?', destination: predictions.at(-1)?.name || 'Destination unavailable',
      direction: ext.direction || (predictions[0]?.id.endsWith('N') ? 'NORTH' : predictions[0]?.id.endsWith('S') ? 'SOUTH' : 'UNKNOWN'),
      timestamp, stops: predictions, relationship: descriptor.schedule_relationship, alerts: [],
      ...(ext.train_id != null ? { trainId: ext.train_id } : {}),
      ...(ext.is_assigned != null ? { assigned: ext.is_assigned } : {}) };
    if (vehicle) train.position = { stopId: vehicle.stop_id,
      name: stops.get(parentStop(vehicle.stop_id || ''))?.name || vehicle.stop_id || 'Unknown stop',
      ...(vehicle.current_status ? { status: vehicle.current_status } : {}),
      ...(vehicle.timestamp != null ? { timestamp: Number(vehicle.timestamp) } : {}) };
    for (const entry of raw.entity || []) {
      if (entry.alert?.informed_entity?.some((s: any) => s.trip?.trip_id === descriptor.trip_id && (!s.trip.start_date || s.trip.start_date === descriptor.start_date))) {
        const title = english(entry.alert.header_text); if (title) train.alerts.push(title);
      }
    }
    trains.set(key, train);
  }
  return trains;
}

export function normalizeAlerts(raw: any): ServiceAlert[] {
  return (raw.entity || []).filter((e: any) => e.alert).map((e: any) => {
    const a = e.alert, ext = extension(a, 'mercury_alert');
    const selectors = (a.informed_entity || []).map((s: any) => ({ route: s.route_id, stop: s.stop_id, trip: s.trip?.trip_id, direction: s.direction_id }));
    return { id: e.id, title: english(a.header_text), description: english(a.description_text), effect: a.effect,
      routes: [...new Set<string>(selectors.map((s: any) => s.route).filter(Boolean))],
      stops: [...new Set<string>([...selectors.map((s: any) => s.stop), ...(ext.affected_stations || []).map((s: any) => s.stop_id)].filter(Boolean))],
      selectors, periods: (a.active_period || []).map((p: any) => ({ start: number(p.start) ?? undefined, end: number(p.end) ?? undefined })),
      updatedAt: number(ext.updated_at) ?? undefined, raw: a };
  });
}
export function alertActive(alert: ServiceAlert, now: number) {
  return !alert.periods.length || alert.periods.some(p => (p.start == null || p.start <= now) && (p.end == null || p.end > now));
}

// Names come from the official station Line field. Local/express is inferred only
// within known station corridors, not from a route's usual daytime reputation.
const corridorAliases: Record<string, string> = { 'Lexington Av': 'Lex', 'Broadway - 7Av': 'Broadway–7 Av', '6th Av - Culver': '6 Av–Culver', '8th Av - Fulton St': '8 Av–Fulton' };
const corridorCache = new WeakMap<Station[], Map<string, Station['parts'][number]>>();
function corridors(catalog: Station[]) {
  let cached = corridorCache.get(catalog);
  if (!cached) {
    cached = new Map(catalog.flatMap(s => s.parts.map(p => [p.id, p] as const))); corridorCache.set(catalog, cached);
  }
  return cached;
}
export function patternFor(train: Train, stopId: string, catalog: Station[]): { label: string; source: 'inferred' | 'static' } {
  const context = corridors(catalog);
  const part = context.get(parentStop(stopId));
  const corridor = part?.line || 'Service pattern';
  const definition = corridorDefinitions.find(c => c.stops.includes(parentStop(stopId)));
  const label = definition?.name || corridorAliases[corridor] || corridor;
  if (!definition) return { label, source: 'static' };
  const index = train.stops.findIndex(s => s.id === stopId);
  const ahead: number[] = [];
  for (const stop of train.stops.slice(index)) {
    const position = definition.stops.indexOf(parentStop(stop.id));
    if (position < 0) break; // Don't infer across a branch departure or reroute.
    if (stop.relationship !== 'SKIPPED') ahead.push(position);
  }
  if (ahead.length < 2) return { label, source: 'static' };
  const skips = ahead.some((value, i) => i > 0 && Math.abs(value - ahead[i - 1]) > 1);
  return { label: `${label} ${skips ? 'express' : 'local'}`, source: 'inferred' };
}
export function locationFor(train: Train) {
  const p = train.position;
  if (p?.stopId) {
    if (p.status === 'STOPPED_AT') return `At ${p.name}`;
    if (p.status === 'INCOMING_AT') return `Approaching ${p.name}`;
    if (p.status === 'IN_TRANSIT_TO') return `In transit to ${p.name}`;
    return `Reported near ${p.name}`;
  }
  return train.stops[0] ? `Next reported stop · ${train.stops[0].name}` : 'Position unavailable';
}
export function buildBoard(station: Station, trains: Iterable<Train>, states: SourceState[], alerts: ServiceAlert[], catalog: Station[], now = nowSeconds()): Board {
  const departures: Departure[] = [];
  for (const train of trains) for (let i = 0; i < train.stops.length; i++) {
    const stop = train.stops[i], part = station.parts.find(p => p.id === parentStop(stop.id));
    if (!part) continue;
    const time = stop.departure ?? stop.arrival;
    // Retain stale last-known rows. Fresh, passed predictions leave the board.
    if (now - train.timestamp <= 90 && time != null && time < now - 30) continue;
    const direction = stop.id.endsWith('N') ? 'NORTH' : stop.id.endsWith('S') ? 'SOUTH' : train.direction;
    const pattern = patternFor(train, stop.id, catalog);
    const relevantTrack = stop.actualTrack || stop.scheduledTrack;
    departures.push({ key: `${train.key}|${stop.id}|${i}`, tripKey: train.key, route: train.route, destination: train.destination,
      direction, stopId: stop.id, partId: part.id,
      area: `${part.line} · ${direction === 'NORTH' ? part.north : direction === 'SOUTH' ? part.south : 'Direction unknown'}${relevantTrack ? ` · Track ${relevantTrack}` : ''}`,
      time, arrival: stop.arrival, scheduledTrack: stop.scheduledTrack, actualTrack: stop.actualTrack,
      pattern: pattern.label, patternSource: pattern.source, location: locationFor(train), locationTimestamp: train.position?.timestamp,
      stopsAway: train.position?.stopId ? (train.stops.findIndex(s => s.id === train.position!.stopId) >= 0 ? i - train.stops.findIndex(s => s.id === train.position!.stopId) : null) : null,
      assigned: train.assigned, feed: train.feed, timestamp: train.timestamp,
      relationship: stop.relationship === 'SKIPPED' ? 'SKIPPED' : train.relationship,
      alerts: train.alerts,
      onward: train.stops.slice(i + 1).filter(s => s.stationId && s.relationship !== 'SKIPPED').map(s => ({ stationId: s.stationId!, stopId: s.id, name: s.name, time: s.arrival ?? s.departure })) });
  }
  departures.sort((a, b) => (a.time ?? Infinity) - (b.time ?? Infinity) || a.key.localeCompare(b.key));
  const routes = new Set([...station.routes, ...departures.map(d => d.route)]);
  const feedIds = new Set(Object.entries(FEED_ROUTES).filter(([, r]) => r.some(x => routes.has(x))).map(([id]) => id));
  if (station.routes.includes('SIR')) feedIds.add('gtfs-si');
  for (const part of station.parts) {
    if (part.line === 'Franklin Shuttle') feedIds.add('gtfs-bdfm');
    if (part.line === 'Lexington - Shuttle') feedIds.add('gtfs');
    if (part.line === 'Rockaway') feedIds.add('gtfs-ace');
  }
  departures.forEach(d => feedIds.add(d.feed));
  const stationStops = new Set(station.parts.map(p => p.id));
  return { station, generatedAt: now, departures, sources: states.filter(s => feedIds.has(s.id) || s.id === 'subway-alerts'),
    alerts: alerts.filter(a => {
      if (!alertActive(a, now)) return false;
      // Selectors are ORed; constraints inside one selector must all match.
      // Agency-wide notices have no narrower selector and still belong here.
      if (a.selectors.length && !a.selectors.some(s =>
        (!s.route || routes.has(s.route)) && (!s.stop || stationStops.has(parentStop(s.stop))) &&
        (!s.trip || departures.some(d => d.tripKey.split('|')[2] === s.trip)))) return false;
      return a.stops.length ? a.stops.some(s => stationStops.has(parentStop(s))) : !a.routes.length || a.routes.some(r => routes.has(r));
    }) };
}
