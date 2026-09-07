import type { AlertSelector, ServiceAlert, SourceState, Train, TripChange } from '../shared/types';
import { daytimePatterns, matchedTrip, serviceTime, type Schedules } from './schedules';
import { changeSummary } from '../shared/changes';

const parent = (id: string) => id.replace(/[NS]$/, '');
const sameStop = (selector: string, stop: string) => /[NS]$/.test(selector) ? selector === stop : parent(selector) === parent(stop);
const active = (a: ServiceAlert, time: number) => !a.periods.length || a.periods.some(p => (p.start == null || p.start <= time) && (p.end == null || time < p.end));
const nightHour = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', hour: 'numeric', hourCycle: 'h23' });
const weekday = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', weekday: 'short' });
const evidence = (source: string, timestamp: number, staleAfter = 90, unavailable = false) => ({ source, timestamp, staleAfter, unavailable });

function selectorMatches(s: AlertSelector, t: Train) {
  const direction = t.direction === 'NORTH' ? 0 : t.direction === 'SOUTH' ? 1 : undefined;
  return (!s.route || s.route === t.route) && (!s.trip || s.trip === t.tripId) &&
    (!s.serviceDate || s.serviceDate === t.serviceDate) && (!s.startTime || s.startTime === t.startTime) &&
    (s.direction == null || s.direction === direction);
}
function classification(a: ServiceAlert): TripChange['classification'] {
  const priorities = a.selectors.map(s => s.priority);
  // Published wording may explain planned maintenance even when the category is Delays.
  if (/\bplanned\b|\bscheduled (?:maintenance|work)/i.test(`${a.alertType || ''} ${a.title} ${a.description}`) || a.planNumbers?.length || priorities.some(p => p != null && p >= 14 && p <= 21)) return 'planned';
  if (/^(?:stops skipped|reroute|detour|express to local|cancellations|part suspended|suspended)$/i.test(a.alertType || '')) return 'unplanned';
  return 'unknown';
}
function alertKind(a: ServiceAlert): TripChange['kind'] {
  if (/boarding change/i.test(a.alertType || '')) return 'boarding';
  if (/stops skipped/i.test(a.alertType || '')) return 'skip';
  if (/reroute|detour|express to local/i.test(a.alertType || '')) return 'pattern';
  return 'advisory';
}
interface Difference { action: string; description: string; stops: string[] }
// Compare only the bounded observed section. Missing predictions at either end
// never establish skipped stops or a shortened trip.
export function patternDifference(before: string[], after: string[], complete = false): Difference | undefined {
  const common = after.flatMap((s, i) => before.indexOf(s) >= 0 && before.indexOf(s) === before.lastIndexOf(s) ? [{ i, j: before.indexOf(s) }] : []);
  if (common.length < 2 || common.some((c, i) => i > 0 && c.j <= common[i-1].j)) return;
  const first = common[0], last = common.at(-1)!;
  const expected = before.slice(first.j, last.j + 1), observed = after.slice(first.i, last.i + 1);
  const omitted = expected.filter(s => !observed.includes(s)), added = observed.filter(s => !expected.includes(s));
  if (omitted.length || added.length) {
    const predecessors = omitted.flatMap(s => {
      const j = before.indexOf(s), previous = common.filter(c => c.j < j).at(-1);
      return previous ? [after[previous.i]] : [];
    });
    return { action: omitted.length && added.length ? 'different route' : omitted.length ? 'skips stops' : 'extra stops',
      description: [omitted.length ? `Does not call at ${omitted.join(', ')}` : '', added.length ? `Additional calls at ${added.join(', ')}` : ''].filter(Boolean).join('. '),
      stops: [...new Set([...omitted, ...added, ...predecessors])] };
  }
  if (complete && after.at(-1) !== before.at(-1) && last.i === after.length - 1 && last.j < before.length - 1) {
    return { action: 'shorter route', description: `Scheduled terminal ${after.at(-1)} instead of ${before.at(-1)}`, stops: [after.at(-1)!] };
  }
}
function names(t: Train, text: string, catalogNames: Map<string, string>) {
  return text.replace(/\b[A-Z]?\d{2,3}[NS]\b/g, id => t.stops.find(s => s.id === id)?.name || catalogNames.get(parent(id)) || id);
}

export class ChangeDetector {
  // Feed normalization produces new Train objects. Helium/board refreshes only
  // change consist enrichment, so reuse the operational analysis until a source
  // changes or a stop/freshness boundary is crossed.
  private results = new WeakMap<Train, { alerts: ServiceAlert[]; schedules?: Schedules; until: number; timestamp: number; alertTimestamp?: number | null; alertError?: string | null; scheduleUnavailable: boolean; trainUnavailable: boolean }>();
  private alertIndices = new WeakMap<ServiceAlert[], Map<string, ServiceAlert[]>>();
  private forRoute(alerts: ServiceAlert[], route: string) {
    let index = this.alertIndices.get(alerts);
    if (!index) {
      index = new Map();
      for (const a of alerts) {
        const routes = !a.selectors.length || a.selectors.some(s => !s.route) ? ['*'] : [...new Set(a.selectors.map(s => s.route!))];
        for (const r of routes) { const list = index.get(r) || []; list.push(a); index.set(r,list); }
      }
      this.alertIndices.set(alerts,index);
    }
    return [...(index.get(route) || []), ...(index.get('*') || [])];
  }
  private tracks = new Map<string, { seen: number; stops: Map<string, { actual?: string; scheduled?: string; event?: { before: string; after: string; timestamp: number; field: string } }> }>();

  enrich(t: Train, alerts: ServiceAlert[], alertState: SourceState | undefined, schedules: Schedules | undefined, now: number, catalogNames = new Map<string, string>(), scheduleUnavailable = false, trainUnavailable = false) {
    const cached = this.results.get(t);
    if (cached && cached.alerts === alerts && cached.schedules === schedules && cached.timestamp === t.timestamp && cached.alertTimestamp === alertState?.timestamp && cached.alertError === alertState?.error && cached.scheduleUnavailable === scheduleUnavailable && cached.trainUnavailable === trainUnavailable && now < cached.until) return t;
    const changes: TripChange[] = [];
    const live = !trainUnavailable && now - t.timestamp <= 90;
    const trainEvidence = evidence(t.feed,t.timestamp,90,trainUnavailable);
    const future = t.stops.flatMap((s, i) => (s.departure ?? s.arrival ?? Infinity) >= now - 30 ? [i] : []);
    const times = future.flatMap(i => { const v = t.stops[i].arrival ?? t.stops[i].departure; return v == null ? [] : [v]; });
    const firstTime = Math.min(...times), lastTime = Math.max(...times);
    const regular = schedules?.version === 2 ? schedules.feeds.find(f => f.name === 'gtfs_subway') : undefined;
    const supplemented = schedules?.version === 2 ? schedules.feeds.find(f => f.name === 'gtfs_supplemented') : undefined;
    const regularMatch = regular && matchedTrip(regular, t);
    const plannedMatch = supplemented && matchedTrip(supplemented, t);
    const expected = plannedMatch || regularMatch;
    const add = (c: Omit<TripChange, 'affectedStops' | 'alertIds'> & { alertIds?: string[]; affectedStops?: string[] }) => {
      if (!c.stopIndices.length) return;
      changes.push({ ...c, affectedStops: c.affectedStops || c.stopIndices.map(i => t.stops[i].id), alertIds: c.alertIds || [] });
    };

    let history = this.tracks.get(t.key);
    if (live && !history) { history = { seen: now, stops: new Map() }; this.tracks.set(t.key, history); }
    if (live && history) history.seen = now;
    for (const i of future) {
      const s = t.stops[i];
      // Repeated stops without sequence IDs cannot safely be linked across snapshots.
      const identity = s.sequence != null ? `${s.id}|${s.sequence}` : t.stops.filter(x => x.id === s.id).length === 1 ? s.id : undefined;
      let previous = identity ? history?.stops.get(identity) : undefined;
      if (live && identity && history) {
        const next = previous ? { ...previous } : {};
        for (const [field, value] of [['actual', s.actualTrack], ['scheduled', s.scheduledTrack]] as const) {
          if (!value) continue;
          if (previous && previous[field] && previous[field] !== value) next.event = { before: previous[field]!, after: value, timestamp: t.timestamp, field };
          next[field] = value;
        }
        history.stops.set(identity, next); previous = next;
      }
      const mismatch = s.actualTrack && s.scheduledTrack && s.actualTrack !== s.scheduledTrack;
      const recorded = previous?.event;
      const event = recorded && (recorded.field === 'actual' ? s.actualTrack : s.scheduledTrack) === recorded.after ? recorded : undefined;
      if (mismatch || event) add({ id: `track:${i}`, kind: 'track', classification: 'unknown', stopIndices: [i], location: s.name,
        label: mismatch ? `track ${s.actualTrack} · scheduled ${s.scheduledTrack}` : `track ${event!.after} · was ${event!.before}`,
        description: mismatch ? `${s.name}: reported track ${s.actualTrack}, scheduled track ${s.scheduledTrack}. Cause not established; this is a stop assignment, not current train position.` : `${s.name}: ${event!.field} track assignment changed from ${event!.before} to ${event!.after}. Cause not established.`,
        before: mismatch ? s.scheduledTrack : event!.before, after: mismatch ? s.actualTrack : event!.after,
        evidence: [trainEvidence] });
      if (s.relationship === 'SKIPPED') add({ id: `skip:${i}`, kind: 'skip', classification: 'unknown', label: `skips ${s.name}`, description: 'Explicitly marked skipped in the live feed.', stopIndices: [i], evidence: [trainEvidence] });
    }
    if (['CANCELED','DELETED'].includes(t.relationship || '')) add({ id: 'cancel', kind: 'cancellation', classification: 'unknown', label: 'canceled', description: 'Explicitly canceled in the live feed.', stopIndices: future, evidence: [trainEvidence] });

    for (const a of this.forRoute(alerts,t.route)) {
      // Skip future/expired notices before expanding station selectors.
      if (!times.length || (a.periods.length && !a.periods.some(p => (p.start == null || p.start <= lastTime) && (p.end == null || p.end > firstTime)))) continue;
      const selectors = a.selectors.length ? a.selectors : [{}];
      const candidates = selectors.filter(s => selectorMatches(s, t));
      if (!candidates.length) continue;
      const affected = (a.affectedSelectors || []).filter(s => selectorMatches(s, t));
      const scope = [...candidates, ...affected];
      const relevant: number[] = [];
      let scheduleUsed = false;
      for (const i of future) {
        const stop = t.stops[i];
        if (!scope.some(s => !s.stop || sameStop(s.stop, stop.id))) continue;
        const time = stop.arrival ?? stop.departure;
        if (time != null && active(a, time)) relevant.push(i);
      }
      // A skipped station may be absent from realtime. Use a uniquely matched
      // schedule and interpolate its passage between two predicted common stops.
      if (!relevant.length && expected && schedules && now - schedules.timestamp <= 7200 && !scheduleUnavailable) {
        const p = expected.pattern;
        for (const s of scope.filter(s => s.stop)) {
          const j = p.stops.findIndex(id => sameStop(s.stop!, id)); if (j < 0) continue;
          const anchors = future.flatMap(i => { const k = p.stops.indexOf(t.stops[i].id), time = t.stops[i].arrival ?? t.stops[i].departure; return k >= 0 && time != null ? [{ i, k, time }] : []; });
          const left = anchors.filter(x => x.k < j).at(-1), right = anchors.find(x => x.k > j);
          if (left && right) {
            const offsets = expected.trip.times, from = offsets[left.k], to = offsets[right.k], at = offsets[j];
            const fraction = from != null && to != null && at != null && to > from ? (at-from)/(to-from) : (j-left.k)/(right.k-left.k);
            if (active(a,left.time+(right.time-left.time)*fraction)) { relevant.push(left.i); scheduleUsed = true; }
          }
        }
      }
      if (!relevant.length) continue;
      const cls = classification(a), kind = alertKind(a);
      const precise = candidates.some(s => s.trip === t.tripId) && !/some trains/i.test(a.title);
      const prefix = cls === 'planned' ? 'planned' : cls === 'unplanned' ? 'disruption' : 'advisory';
      const action = (a.alertType || 'service change').replace(/^Planned\s*-\s*/i, '').toLowerCase();
      add({ id: `alert:${a.id}`, kind, classification: cls, advisory: !precise,
        label: `${prefix} · ${action}`, description: `${precise ? '' : 'Published advisory; individual train impact may vary. '}${a.title}\n${a.description}${a.activePeriodLabel ? `\n${a.activePeriodLabel}` : ''}`,
        stopIndices: [...new Set(relevant)], affectedStops: [...new Set(scope.flatMap(s => s.stop ? [s.stop] : []))], alertIds: [a.id],
        evidence: [evidence('subway-alerts', alertState?.timestamp || 0, 90, !!alertState?.error), trainEvidence, ...(scheduleUsed ? [evidence('schedules',schedules!.timestamp,7200)] : [])] });
    }

    if (regular && schedules && expected && !scheduleUnavailable && now - schedules.timestamp <= 7200) {
      const scheduleEvidence = [evidence('schedules',schedules.timestamp,7200), trainEvidence];
      const full = expected.pattern.stops;
      const observed = t.stops.filter(s => s.relationship !== 'SKIPPED').map(s => s.id);
      let cursor = -1;
      const compatible = observed.every(s => { cursor = full.indexOf(s,cursor+1); return cursor >= 0; });
      const deviation = patternDifference(full, observed);
      if (deviation) add({ id: 'live-pattern', kind: 'pattern', classification: 'unknown', label: `reported · ${deviation.action}`,
        description: names(t, `${deviation.description}. Different from the matched current schedule; cause not established.`, catalogNames), affectedStops: deviation.stops,
        stopIndices: future.filter(i => deviation.stops.includes(t.stops[i].id)), evidence: scheduleEvidence });
      const planDifference = plannedMatch && regularMatch && patternDifference(regularMatch.pattern.stops, full, true);
      if (compatible && !deviation && planDifference) add({ id: 'planned-pattern', kind: 'pattern', classification: 'planned',
        label: `planned · ${planDifference.action}`, description: names(t, `${planDifference.description}. The supplemented schedule differs from the regular trip for this service date.`,catalogNames),
        affectedStops: planDifference.stops, stopIndices: future.filter(i => planDifference.stops.includes(t.stops[i].id)), evidence: scheduleEvidence });
      const baseline = daytimePatterns(regular, t);
      // Preserve destination branches. A contained scheduled short turn may be
      // compared only when the daytime alternatives agree on the difference.
      let candidates = baseline.filter(p => p.stops.at(-1) === full.at(-1));
      if (!candidates.length) candidates = baseline.filter(p => p.stops[0] === full[0] && p.stops.includes(full.at(-1)!));
      const comparisons = candidates.map(p => patternDifference(p.stops, full, true));
      const defined = comparisons.filter((d): d is Difference => !!d);
      if (compatible && !deviation && !planDifference && defined.length && defined.length === comparisons.length && new Set(defined.map(d => JSON.stringify(d))).size === 1) {
        const d = defined[0];
        const sampleTime = t.stops[future[0]]?.arrival ?? t.stops[future[0]]?.departure ?? (expected.trip.start == null ? now : serviceTime(t.serviceDate!,expected.trip.start));
        const hour = Number(nightHour.format(sampleTime * 1000));
        const period = hour >= 22 || hour < 6 ? 'overnight' : ['Sat','Sun'].includes(weekday.format(sampleTime*1000)) ? 'weekend' : 'scheduled';
        const differenceNames = names(t, d.description, catalogNames);
        add({ id: 'scheduled-pattern', kind: 'pattern', classification: 'scheduled',
          label: `${period} · ${d.action}`,
          description: `${differenceNames}. Compared with regular weekday daytime service. This matches the published schedule for this trip.`,
          affectedStops: d.stops, stopIndices: future.filter(i => d.stops.includes(t.stops[i].id)), evidence: scheduleEvidence });
      }
    }
    // Advisory evidence can explain a change, but route-level alerts cannot prove
    // its cause. Preserve both rather than upgrading unknown to unplanned.
    t.changes = changes;
    for (let i = 0; i < t.stops.length; i++) t.stops[i].changes = changes.filter(c => c.stopIndices.includes(i)).map(changeSummary);
    const boundaries = [...times.map(time => time+31), t.timestamp+91, ...(schedules ? [schedules.timestamp+7201] : [])].filter(time => time > now);
    this.results.set(t,{alerts,schedules,until:Math.min(...boundaries),timestamp:t.timestamp,alertTimestamp:alertState?.timestamp,alertError:alertState?.error,scheduleUnavailable,trainUnavailable});
    return t;
  }
  prune(now: number) {
    for (const [key, value] of this.tracks) if (now - value.seen > 900) this.tracks.delete(key);
    while (this.tracks.size > 10000) this.tracks.delete(this.tracks.keys().next().value!);
  }
}
