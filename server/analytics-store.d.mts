import type { AnalyticsEvent, Stats } from '../shared/analytics';
export class AnalyticsStore {
  constructor(file: string, now?: number);
  record(events: AnalyticsEvent[], now?: number): void;
  cleanup(now: number): void;
  stats(range: string, now?: number): Stats;
  close(): void;
}
