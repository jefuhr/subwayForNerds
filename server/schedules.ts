import type { Train } from '../shared/types';

export interface SchedulePattern { route: string; shape: string; headsign: string; stops: string[]; source: string }
export interface Schedules { timestamp: number; feeds: { name: string; stops: { stop_id: string; stop_name: string }[]; patterns: SchedulePattern[] }[] }
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
