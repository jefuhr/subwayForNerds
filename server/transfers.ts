import type { Board, Train, TransferResult } from '../shared/types';
import { boardable, freshness } from '../shared/display';
import { currentConsist } from '../shared/consist';

export function transfers(train: Train | undefined, boards: Map<string, Board>, stopId: string, sequence: number | undefined, now: number): TransferResult {
  const empty: TransferResult = { arrival: null, basis: 'arrival', connections: [], sources: [] };
  if (!train) return { ...empty, message: 'This train is no longer reporting.' };
  const matches = train.stops.filter(s => s.id === stopId && (sequence === undefined || s.sequence === sequence));
  if (matches.length !== 1) return { ...empty, message: 'This stop was removed or its visit is ambiguous. Reopen train details.' };
  const stop = matches[0], board = boards.get(stop.stationId || '');
  const arrival = stop.arrival ?? stop.departure, basis = stop.arrival == null ? 'departure' : 'arrival';
  const result: TransferResult = { ...empty, arrival, basis, originTimestamp: train.timestamp, station: board?.station, sources: board?.sources || [] };
  if (!board) return { ...result, message: 'Station complex unavailable.' };
  const originSource = board.sources.find(s => s.id === train.feed);
  if (freshness(train.timestamp, now) !== 'live' || originSource?.error) return { ...result, message: 'Your train’s prediction is stale or unavailable.' };
  if (['CANCELED', 'DELETED'].includes(train.relationship || '') || stop.relationship === 'SKIPPED' || train.assigned === false) return { ...result, message: 'This train is not boarding at this stop.' };
  if (arrival == null) return { ...result, message: 'No arrival estimate for this stop yet.' };
  if (arrival < now) return { ...result, message: 'This arrival estimate has passed. Awaiting an update.' };
  const ownCars = currentConsist(train.consist, now) ? new Set(train.consist.cars.map(c => c.number)) : new Set<string>();
  result.connections = board.departures.filter(d => d.tripKey !== train.key && boardable(d) && d.assigned !== false &&
    freshness(d.timestamp, now) === 'live' && !board.sources.find(s => s.id === d.feed)?.error &&
    d.time != null && d.time >= arrival && d.time <= arrival + 1800 &&
    !(currentConsist(d.consist, now) && d.consist.cars.some(c => ownCars.has(c.number))))
    .map(d => ({ ...d, gap: d.time! - arrival, basis: d.departure == null ? 'arrival' as const : 'departure' as const }));
  if (!result.connections.length) result.message = 'No fresh connections reported in the 30 minutes after arrival. The feed may not predict that far ahead.';
  return result;
}
