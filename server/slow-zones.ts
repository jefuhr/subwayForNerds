import { zstdDecompressSync } from 'node:zlib';
import { parquetReadObjects } from 'hyparquet';
import type { SlowZone, SourceState, StopPrediction, Train, TrainSlowZone } from '../shared/types';
import { slowZoneSummary } from '../shared/slow-zones';

// Transit Lab estimates slow zones from archived segment run times (CC BY 4.0).
export const SLOW_ZONES_URL = 'https://data.transitlab.nyc/v1/subway_slow_zones.parquet';
// Transit Lab's site counts zones that ended within a week of its latest data as active.
const ACTIVE_DAYS = 7, STALE_DAYS = 14, HISTORY_TTL = 900, HISTORY_LIMIT = 10000;
const KINDS: Record<string, SlowZone['kind']> = { 'slow zone': 'slow', disruption: 'disruption' };
const COLUMNS = ['a_stop', 'b_stop', 'segment', 'routes', 'start_date', 'end_date', 'slow_days', 'baseline_s', 'extra_s_median', 'kind'];

export interface SlowZoneRow {
  a_stop: string; b_stop: string; segment: string; routes: string; start_date: string; end_date: string;
  slow_days: number; baseline_s: number; extra_s_median: number; kind: string;
}
export interface ActiveSlowZone extends SlowZone { routes: string[] }
export interface SlowZoneSnapshot { version: 1; dataThrough: string; zones: ActiveSlowZone[]; etag?: string; state: SourceState }

const isoDate = (days: number) => new Date(days * 86400000).toISOString().slice(0, 10);
const dayNumber = (date: string) => Date.parse(date + 'T00:00:00Z') / 86400000;
const eastern = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' });
const stopPattern = /^[0-9A-Z]+[NS]$/, datePattern = /^\d{4}-\d{2}-\d{2}$/;

// First Eastern midnight outside the inclusive 14-day window, including DST changes.
function expiry(dataThrough: string): number | null {
  const day = dayNumber(dataThrough) + STALE_DAYS + 1;
  if (!Number.isFinite(day)) return null;
  let low = day * 86400 - 86400, high = day * 86400 + 86400;
  while (high - low > 1) {
    const middle = Math.floor((low + high) / 2);
    if (dayNumber(eastern.format(middle * 1000)) >= day) high = middle; else low = middle;
  }
  return high;
}

export async function decodeSlowZones(bytes: Uint8Array): Promise<SlowZoneRow[]> {
  const file = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  const rows = await parquetReadObjects({ file, columns: COLUMNS, compressors: { ZSTD: input => zstdDecompressSync(input) }, parsers: { dateFromDays: isoDate } });
  return rows.flatMap(r => {
    const row: SlowZoneRow = { a_stop: String(r.a_stop ?? ''), b_stop: String(r.b_stop ?? ''), segment: String(r.segment ?? ''), routes: String(r.routes ?? ''),
      start_date: String(r.start_date ?? ''), end_date: String(r.end_date ?? ''), slow_days: Number(r.slow_days), baseline_s: Number(r.baseline_s),
      extra_s_median: Number(r.extra_s_median), kind: String(r.kind ?? '') };
    const valid = stopPattern.test(row.a_stop) && stopPattern.test(row.b_stop) && datePattern.test(row.start_date) && datePattern.test(row.end_date) &&
      [row.slow_days, row.baseline_s, row.extra_s_median].every(Number.isFinite);
    return valid ? [row] : [];
  });
}

export function activeSlowZones(rows: SlowZoneRow[]): { dataThrough: string | null; zones: ActiveSlowZone[] } {
  let dataThrough: string | null = null;
  for (const r of rows) if (!dataThrough || r.end_date > dataThrough) dataThrough = r.end_date;
  if (!dataThrough) return { dataThrough, zones: [] };
  const cutoff = isoDate(dayNumber(dataThrough) - ACTIVE_DAYS);
  // A segment can have a finished episode and a new one inside the window; keep the latest.
  const pairs = new Map<string, SlowZoneRow>();
  for (const r of rows) {
    if (!KINDS[r.kind] || r.end_date < cutoff) continue;
    const key = r.a_stop + '|' + r.b_stop, existing = pairs.get(key);
    if (!existing || r.end_date > existing.end_date || (r.end_date === existing.end_date && r.start_date > existing.start_date)) pairs.set(key, r);
  }
  return { dataThrough, zones: [...pairs.values()].map(r => ({ from: r.a_stop, to: r.b_stop, segment: r.segment, kind: KINDS[r.kind],
    since: r.start_date, through: r.end_date, extraSeconds: r.extra_s_median, baselineSeconds: r.baseline_s, slowDays: r.slow_days,
    routes: r.routes.split(/\s+/).filter(Boolean) })) };
}

interface History { stopId: string; previous?: string; seen: number }
export class SlowZoneService {
  state: SourceState = { id: 'slow-zones', timestamp: null, fetchedAt: null, error: null };
  dataThrough: string | null = null;
  expiresAt: number | null = null;
  revision = 0;
  etag?: string;
  zones: ActiveSlowZone[] = [];
  private pairs = new Map<string, ActiveSlowZone>();
  private ends = new Map<string, ActiveSlowZone[]>();
  private history = new Map<string, History>();

  accept(rows: SlowZoneRow[], meta: { fetchedAt: number; timestamp?: number | null; etag?: string; minimumRows?: number }) {
    if (meta.minimumRows && rows.length < meta.minimumRows) throw new Error(`Incomplete slow zone dataset (${rows.length} rows)`);
    const { dataThrough, zones } = activeSlowZones(rows);
    if (!dataThrough) throw new Error('Slow zone dataset has no episodes');
    this.index(dataThrough, zones);
    this.etag = meta.etag;
    this.state = { id: 'slow-zones', timestamp: meta.timestamp ?? meta.fetchedAt, fetchedAt: meta.fetchedAt, error: null };
  }
  restore(snapshot: SlowZoneSnapshot) {
    if (snapshot?.version !== 1 || typeof snapshot.dataThrough !== 'string' || !Array.isArray(snapshot.zones)) throw new Error('Incompatible slow zone cache');
    this.index(snapshot.dataThrough, snapshot.zones);
    this.etag = snapshot.etag;
    this.state = { ...snapshot.state, id: 'slow-zones' };
  }
  snapshot(): SlowZoneSnapshot {
    return { version: 1, dataThrough: this.dataThrough!, zones: this.zones, ...(this.etag ? { etag: this.etag } : {}), state: this.state };
  }
  private index(dataThrough: string, zones: ActiveSlowZone[]) {
    this.dataThrough = dataThrough; this.zones = zones;
    this.expiresAt = expiry(dataThrough);
    this.revision++;
    this.pairs = new Map(zones.map(z => [z.from + '|' + z.to, z]));
    this.ends = new Map();
    for (const z of zones) this.ends.set(z.to, [...(this.ends.get(z.to) || []), z]);
  }
  // A dataset that stops updating must not keep describing old track conditions.
  live(now: number) {
    return !!this.dataThrough && dayNumber(eastern.format(now * 1000)) - dayNumber(this.dataThrough) <= STALE_DAYS;
  }
  health(now: number) {
    const live = this.live(now);
    return { status: !this.dataThrough ? 'unavailable' : live && !this.state.error ? 'ok' : 'degraded', dataThrough: this.dataThrough,
      active: live ? this.zones.length : 0, timestamp: this.state.timestamp, fetchedAt: this.state.fetchedAt,
      fetchAge: this.state.fetchedAt == null ? null : now - this.state.fetchedAt, error: this.state.error };
  }
  enrich(train: Train, now: number) {
    delete train.slowZones;
    if (!train.feed.startsWith('gtfs')) return;
    const { position, stops } = train;
    const previous = position?.stopId ? this.observe(train.key, position.stopId, stops, now) : undefined;
    if (!this.pairs.size || !this.live(now)) return;
    const at = position?.stopId ? stops.findIndex(s => s.id === position.stopId) : -1;
    const zones: TrainSlowZone[] = [];
    if (moving(train, at) && stops[at].relationship !== 'SKIPPED') {
      const end = stops[at].id;
      const from = previous ?? servedBefore(stops, at) ?? scheduledBefore(train, end);
      const zone = from ? this.pairs.get(from + '|' + end) : this.uniqueEnd(end, train.route);
      if (zone) zones.push({ ...slowZoneSummary(zone), toIndex: at, current: true });
    }
    let last = -1;
    for (let i = Math.max(at, 0); i < stops.length; i++) {
      if (stops[i].relationship === 'SKIPPED') continue;
      const zone = last >= 0 ? this.pairs.get(stops[last].id + '|' + stops[i].id) : undefined;
      if (zone) zones.push({ ...slowZoneSummary(zone), toIndex: i });
      last = i;
    }
    if (zones.length) train.slowZones = zones;
  }
  prune(now: number) {
    for (const [key, entry] of this.history) if (now - entry.seen > HISTORY_TTL) this.history.delete(key);
  }
  // Without an observed or reported predecessor, only an end stop measured on this route is unambiguous.
  private uniqueEnd(end: string, route: string) {
    const candidates = (this.ends.get(end) || []).filter(z => z.routes.includes(route));
    return candidates.length === 1 ? candidates[0] : undefined;
  }
  private observe(key: string, stopId: string, stops: StopPrediction[], now: number) {
    const entry = this.history.get(key) || { stopId, seen: now };
    if (entry.stopId !== stopId) {
      const at = stops.findIndex(s => s.id === stopId);
      // A report of a stop that is still ahead is a regression, not the stop just left.
      entry.previous = at >= 0 && stops.slice(at).some(s => s.id === entry.stopId) ? undefined : entry.stopId;
      entry.stopId = stopId;
    }
    entry.seen = now;
    this.history.delete(key); this.history.set(key, entry);
    if (this.history.size > HISTORY_LIMIT) this.history.delete(this.history.keys().next().value!);
    return entry.previous;
  }
}
// NYCT omits current_status for many moving trains (GTFS-rt's default is IN_TRANSIT_TO).
// Without it, require a report no newer than the feed (unstarted trips carry future
// placeholder times), the reported stop to be the next prediction, and that arrival ahead.
function moving(train: Train, at: number) {
  const position = train.position, head = train.stops[at];
  if (at < 0 || !position) return false;
  if (position.status) return position.status === 'IN_TRANSIT_TO' || position.status === 'INCOMING_AT';
  return at === 0 && position.timestamp != null && position.timestamp <= train.timestamp && head.arrival != null && head.arrival > train.timestamp;
}
function servedBefore(stops: StopPrediction[], index: number) {
  for (let i = index - 1; i >= 0; i--) if (stops[i].relationship !== 'SKIPPED') return stops[i].id;
}
function scheduledBefore(train: Train, stopId: string) {
  const stops = train.scheduledPattern?.stops || [], index = stops.indexOf(stopId);
  return index > 0 && index === stops.lastIndexOf(stopId) ? stops[index - 1] : undefined;
}
