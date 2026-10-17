import type { SlowZone, Train } from './types';

export function slowZoneSummary({ from, to, segment, kind, since, through, extraSeconds, baselineSeconds, slowDays }: SlowZone): SlowZone {
  return { from, to, segment, kind, since, through, extraSeconds, baselineSeconds, slowDays };
}
export const currentSlowZone = (train: Pick<Train, 'slowZones'>) => train.slowZones?.find(z => z.current);
export const slowZoneLabel = (zone: Pick<SlowZone, 'kind'>) => zone.kind === 'disruption' ? 'major slowdown' : 'slow zone';
export function slowZoneSeconds(seconds: number) {
  const total = Math.max(0, Math.round(seconds));
  return total < 60 ? `${total}s` : `${Math.floor(total / 60)}m${total % 60 ? ` ${total % 60}s` : ''}`;
}
export function slowZoneDate(date: string) {
  return new Date(date + 'T12:00:00Z').toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
}
