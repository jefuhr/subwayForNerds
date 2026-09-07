import type { Train } from '../shared/types';

export interface SchedulePattern { route: string; shape: string; headsign: string; stops: string[]; source: string; direction?: number }
export interface ScheduleTrip { id: string; service: string; pattern: number; start: number | null; times: (number | null)[] }
export interface ScheduleFeed {
  name: string; stops: { stop_id: string; stop_name: string }[]; patterns: SchedulePattern[];
  trips?: ScheduleTrip[]; calendar?: Record<string, string>[]; exceptions?: Record<string, string>[];
}
export interface Schedules { version?: number; timestamp: number; feeds: ScheduleFeed[] }

export const tripSuffix = (id: string) => id.match(/(-?\d+_[^_]+)$/)?.[1] || id;
const weekdays = ['sunday','monday','tuesday','wednesday','thursday','friday','saturday'];
export function serviceActive(feed: ScheduleFeed, service: string, date: string): boolean {
  if (!/^\d{8}$/.test(date)) return false;
  const exception = feed.exceptions?.find(e => e.service_id === service && e.date === date);
  if (exception) return exception.exception_type === '1';
  const day = new Date(`${date.slice(0,4)}-${date.slice(4,6)}-${date.slice(6,8)}T12:00:00Z`).getUTCDay();
  return !!feed.calendar?.some(c => c.service_id === service && c.start_date <= date && c.end_date >= date && c[weekdays[day]] === '1');
}
const easternParts = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
// GTFS times are elapsed seconds from local noon minus twelve hours, including DST days.
export function serviceTime(date: string, seconds: number): number {
  const utcNoon = Date.UTC(Number(date.slice(0,4)), Number(date.slice(4,6)) - 1, Number(date.slice(6,8)), 12) / 1000;
  const parts = Object.fromEntries(easternParts.formatToParts(utcNoon * 1000).map(p => [p.type, p.value]));
  const wall = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second) / 1000;
  return utcNoon + (utcNoon - wall) - 43200 + seconds;
}
interface FeedIndex { ids: Map<string, ScheduleTrip[]>; origins: Map<string, ScheduleTrip[]>; baseline: Map<string, ScheduleTrip[]> }
const indices = new WeakMap<ScheduleFeed, FeedIndex>();
function index(feed: ScheduleFeed) {
  let result = indices.get(feed); if (result) return result;
  result = { ids: new Map(), origins: new Map(), baseline: new Map() };
  const add = (map: Map<string, ScheduleTrip[]>, key: string, t: ScheduleTrip) => { const a = map.get(key) || []; a.push(t); map.set(key, a); };
  for (const t of feed.trips || []) {
    const p = feed.patterns[t.pattern]; if (!p) continue;
    add(result.ids, `${p.route}|${tripSuffix(t.id)}`, t);
    const origin = tripSuffix(t.id).split('_')[0];
    add(result.origins, `${p.route}|${p.direction}|${origin}`, t);
    add(result.baseline, `${p.route}|${p.direction}`, t);
  }
  indices.set(feed, result); return result;
}
export function matchedTrip(feed: ScheduleFeed, train: Train): { trip: ScheduleTrip; pattern: SchedulePattern } | undefined {
  if (!train.serviceDate) return;
  const direction = train.direction === 'NORTH' ? 0 : train.direction === 'SOUTH' ? 1 : undefined;
  const idx = index(feed);
  const valid = (t: ScheduleTrip) => serviceActive(feed, t.service, train.serviceDate!) && (direction == null || feed.patterns[t.pattern].direction === direction);
  let candidates = (idx.ids.get(`${train.route}|${tripSuffix(train.tripId)}`) || []).filter(valid);
  if (!candidates.length && direction != null) candidates = (idx.origins.get(`${train.route}|${direction}|${tripSuffix(train.tripId).split('_')[0]}`) || []).filter(valid);
  // Equivalent calendar duplicates are harmless; different patterns/timings are not.
  const unique = new Map(candidates.map(t => [JSON.stringify([t.pattern,t.times]), t]));
  if (unique.size !== 1) return;
  const trip = [...unique.values()][0]; return { trip, pattern: feed.patterns[trip.pattern] };
}
const baselineCache = new WeakMap<ScheduleFeed, Map<string, SchedulePattern[]>>();
export function daytimePatterns(feed: ScheduleFeed, train: Train): SchedulePattern[] {
  const direction = train.direction === 'NORTH' ? 0 : train.direction === 'SOUTH' ? 1 : undefined;
  if (direction == null || !train.serviceDate) return [];
  let cache = baselineCache.get(feed); if (!cache) { cache = new Map(); baselineCache.set(feed, cache); }
  const key = `${train.route}|${direction}|${train.serviceDate}`;
  const cached = cache.get(key); if (cached) return cached;
  const services = new Set(feed.calendar?.filter(c => c.start_date <= train.serviceDate! && c.end_date >= train.serviceDate! && weekdays.slice(1,6).some(d => c[d] === '1')).map(c => c.service_id));
  const candidates = (index(feed).baseline.get(`${train.route}|${direction}`) || []).filter(t => services.has(t.service));
  let daytime = candidates.filter(t => t.start != null && t.start >= 36000 && t.start < 57600);
  if (!daytime.length) daytime = candidates.filter(t => t.start != null && t.start >= 21600 && t.start < 79200);
  const result = [...new Set(daytime.map(t => t.pattern))].map(i => feed.patterns[i]);
  if (cache.size > 1000) cache.clear();
  cache.set(key, result); return result;
}
export function enrichSchedule(train: Train, schedules?: Schedules): Train {
  if (!schedules) return train;
  const shape = train.tripId.slice(train.tripId.indexOf('_') + 1);
  // Show a static comparison only for a matching shape and compatible remaining
  // sequence. It is context, never an arrival or a replacement for realtime.
  for (const feed of [...schedules.feeds].reverse()) {
    const matches = (feed.patterns || []).filter(p => p.route === train.route && p.shape === shape && train.stops.every(s => p.stops.includes(s.id)));
    if (matches.length !== 1) continue;
    const pattern = matches[0];
    let last = -1;
    const ordered = train.stops.every(s => { const i = pattern.stops.indexOf(s.id, last + 1); if (i < 0) return false; last = i; return true; });
    if (!ordered) continue;
    train.scheduledPattern = pattern;
    break;
  }
  return train;
}
