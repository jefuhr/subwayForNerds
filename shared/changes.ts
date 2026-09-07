import type { TripChange } from './types';

export function changesAhead(changes: TripChange[] | undefined, index: number): TripChange[] {
  return (changes || []).filter(c => c.stopIndices.some(i => i >= index)).sort((a, b) => changeRank(a, index) - changeRank(b, index) || a.id.localeCompare(b.id)).map(c =>
    (c.kind === 'track' || c.kind === 'boarding') && !c.stopIndices.includes(index) ? { ...c, label: `${c.label} · ahead${c.location ? ` at ${c.location}` : ''}` } : c);
}
export function changeSummary({ description: _description, ...summary }: TripChange): TripChange { return summary; }
function changeRank(c: TripChange, index: number) {
  if ((c.kind === 'track' || c.kind === 'boarding') && c.stopIndices.includes(index)) return 0;
  if (c.kind === 'cancellation') return 1;
  if (c.classification === 'unplanned' || c.classification === 'unknown') return c.advisory ? 3 : 2;
  return c.classification === 'planned' ? 4 : 5;
}
export function changeStale(c: TripChange, now: number, cached = false) {
  return cached || c.evidence.some(e => e.unavailable || !e.timestamp || now - e.timestamp > e.staleAfter);
}
