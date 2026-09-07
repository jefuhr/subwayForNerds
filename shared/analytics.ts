export const eventNames = ['session_start', 'station_view', 'favorite_add', 'favorite_remove', 'direction', 'line', 'reset', 'train_open', 'fleet_open'] as const;
export type EventName = typeof eventNames[number];
export type AnalyticsEvent = { id: string; browser: string; session: string; name: EventName; station?: string; device: 'phone' | 'tablet' | 'desktop'; referrer: string };
export type Stats = { range: string; collectedSince: number; updatedAt: number; visits: number; browsers: number; returning: number; views: number; daily: { date: string; visits: number; views: number }[]; stations: { label: string; count: number }[]; devices: { label: string; count: number }[]; referrers: { label: string; count: number }[]; interactions: { label: string; count: number }[] };
