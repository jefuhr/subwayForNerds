import type { Departure } from './types';

export const freshness = (timestamp: number | null | undefined, now: number) =>
  !timestamp ? 'unavailable' : now - timestamp > 300 ? 'expired' : now - timestamp > 90 ? 'stale' : 'live';
export function countdown(time: number | null, timestamp: number, now: number, cached = false) {
  if (time == null) return { value: '—', unit: 'no estimate' };
  if (cached || freshness(timestamp, now) !== 'live') return { value: clockTime(time), unit: 'last estimate' };
  const seconds = time - now;
  if (seconds < -30) return { value: '—', unit: 'awaiting update' };
  if (seconds < 60) return { value: '<1', unit: 'min' };
  return { value: String(Math.floor(seconds / 60)), unit: 'min' };
}
export const clockTime = (seconds: number | null | undefined) => seconds == null ? '—' : new Intl.DateTimeFormat('en-US', {
  hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York',
}).format(new Date(seconds * 1000));
export function ageLabel(timestamp: number | null | undefined, now: number) {
  if (!timestamp) return 'not received';
  const seconds = Math.max(0, now - timestamp);
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  return `${Math.floor(seconds / 3600)}h ago`;
}
export const boardable = (d: Departure) => !['SKIPPED', 'CANCELED', 'DELETED'].includes(d.relationship || '');
export function firstTo(departures: Departure[], destination: string, now: number) {
  return departures.filter(d => boardable(d) && freshness(d.timestamp, now) === 'live' && d.time != null && d.time >= now)
    .flatMap(d => {
      const stop = d.onward.find(s => s.stationId === destination);
      return stop?.time != null && stop.time >= d.time! ? [{ key: d.key, time: stop.time }] : [];
    }).sort((a, b) => a.time - b.time)[0];
}
export function distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number) {
  const rad = Math.PI / 180, dlat = (lat2 - lat1) * rad, dlon = (lon2 - lon1) * rad;
  const a = Math.sin(dlat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
