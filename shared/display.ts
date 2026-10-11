import type { Departure } from './types';
import type { UnitSettings } from './settings';

export const freshness = (timestamp: number | null | undefined, now: number) =>
  !timestamp ? 'unavailable' : now - timestamp > 300 ? 'expired' : now - timestamp > 90 ? 'stale' : 'live';
export function countdown(time: number | null, timestamp: number, now: number, cached = false, format: UnitSettings['time'] = '12h') {
  if (time == null) return { value: '—', unit: 'no estimate' };
  if (cached || freshness(timestamp, now) !== 'live') return { value: clockTime(time, format), unit: 'last estimate' };
  const seconds = time - now;
  if (seconds < -30) return { value: '—', unit: 'awaiting update' };
  if (seconds < 60) return { value: '<1', unit: 'min' };
  return { value: String(Math.floor(seconds / 60)), unit: 'min' };
}
const clockOptions = (format: UnitSettings['time']): Intl.DateTimeFormatOptions => ({
	hour: format === '24h' ? '2-digit' : 'numeric', minute: '2-digit', timeZone: 'America/New_York', hourCycle: format === '24h' ? 'h23' : 'h12',
});
export const clockTime = (seconds: number | null | undefined, format: UnitSettings['time'] = '12h') => seconds == null ? '—' : new Intl.DateTimeFormat('en-US', clockOptions(format)).format(new Date(seconds * 1000));
export const clockDateTime = (seconds: number, format: UnitSettings['time'] = '12h') => new Intl.DateTimeFormat('en-US', {
	year: 'numeric', month: 'numeric', day: 'numeric', ...clockOptions(format), second: '2-digit',
}).format(new Date(seconds * 1000));
/** Published MTA outage strings are already local wall time; do not reinterpret them in the browser's timezone. */
export function sourceClockText(value: string, format: UnitSettings['time'] = '12h'): string {
	const match = /^(\d{1,2}\/\d{1,2}\/\d{4})\s+(\d{1,2}):([0-5]\d)(?::([0-5]\d))?(?:\s+(AM|PM))?$/i.exec(value);
	if (!match) return value;
	const [, date, hourText, minute, second, period] = match;
	let hour = Number(hourText);
	if (period ? hour < 1 || hour > 12 : hour > 23) return value;
	if (period) hour = hour % 12 + (period.toUpperCase() === 'PM' ? 12 : 0);
	const minutes = `${minute}${second ? ':' + second : ''}`;
	if (format === '24h') return `${date} ${String(hour).padStart(2, '0')}:${minutes}`;
	return period ? value : `${date} ${hour % 12 || 12}:${minutes} ${hour < 12 ? 'AM' : 'PM'}`;
}

export const distanceUnitNames = { auto: 'feet', mi: 'miles', ft: 'feet', m: 'meters', km: 'kilometers' } as const;
export const radiusUnit = (unit: UnitSettings['distance']) => unit === 'auto' ? 'ft' : unit;
const feetPerUnit = { auto: 1, ft: 1, mi: 5280, m: 1 / 0.3048, km: 1000 / 0.3048 } as const;
/** Eight decimal places preserve every supported integer-foot boundary in every display unit. */
export const radiusDisplayValue = (feet: number, unit: UnitSettings['distance']) => String(Number((feet / feetPerUnit[unit]).toFixed(8)));
export function radiusFeetFromInput(value: string, unit: UnitSettings['distance']): number | null {
	if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(value)) return null;
	const feet = Number(value) * feetPerUnit[unit];
	// Allow only the representation error from the eight-decimal unit editor.
	const tolerance = feetPerUnit[unit] * 0.000000005 + 0.000000001;
	return Number.isFinite(feet) && feet >= 1 - tolerance && feet <= 26400 + tolerance ? Math.round(feet) : null;
}
export function distanceLabel(meters: number, unit: UnitSettings['distance'] = 'auto'): string {
	if (unit === 'auto') return meters < 1000 ? `${Math.round(meters)} m` : `${(meters / 1000).toFixed(1)} km`;
	const value = unit === 'mi' ? meters / 1609.344 : unit === 'ft' ? meters / 0.3048 : unit === 'km' ? meters / 1000 : meters;
	const decimals = unit === 'mi' || unit === 'km' ? 2 : 0;
	return `${value > 0 && value < 0.01 && decimals ? '<0.01' : value.toLocaleString('en-US', { maximumFractionDigits: decimals })} ${unit}`;
}
export function ageLabel(timestamp: number | null | undefined, now: number) {
  if (!timestamp) return 'not received';
  const seconds = Math.max(0, now - timestamp);
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  return `${Math.floor(seconds / 3600)}h ago`;
}
export const boardable = (d: Departure) => !['SKIPPED', 'CANCELED', 'DELETED'].includes(d.relationship || '');
export function distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number) {
  const rad = Math.PI / 180, dlat = (lat2 - lat1) * rad, dlon = (lon2 - lon1) * rad;
  const a = Math.sin(dlat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
