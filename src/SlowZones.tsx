import { Snail } from 'lucide-react';
import type { SlowZone, TrainSlowZone } from '../shared/types';
import { slowZoneDate, slowZoneLabel, slowZoneSeconds } from '../shared/slow-zones';
import './slow-zones.css';

export const slowZoneDescription = (zone: SlowZone) => `In an estimated ${slowZoneLabel(zone)}: ${zone.segment}, typically ${slowZoneSeconds(zone.extraSeconds)} slower`;

export function SlowZoneTag({ zone }: { zone: SlowZone }) {
  return <span className={`slow-zone-tag slow-zone-${zone.kind}`} title={slowZoneDescription(zone)}><Snail size={12} aria-hidden="true" />+{slowZoneSeconds(zone.extraSeconds)}</span>;
}
export function SlowZoneSummary({ zones }: { zones?: TrainSlowZone[] }) {
  if (!zones?.length) return null;
  const total = zones.reduce((sum, zone) => sum + zone.extraSeconds, 0);
  return <p className="slow-zone-summary"><Snail size={14} aria-hidden="true" />{zones.length} estimated slow {zones.length === 1 ? 'zone' : 'zones'} ahead · about +{slowZoneSeconds(total)} typical</p>;
}
// Rendered between two stops; `live` false hides the "now" marker for stale reports.
export function SlowZoneSegment({ zone, live }: { zone: TrainSlowZone; live: boolean }) {
  const now = zone.current && live;
  return <li className={`slow-segment slow-zone-${zone.kind}${now ? ' slow-segment-now' : ''}`}>
    <span className="slow-segment-icon"><Snail size={12} aria-hidden="true" /></span>
    <div><strong>{slowZoneLabel(zone)}{now ? ' · now' : ''}</strong>
      <small>{zone.segment} · +{slowZoneSeconds(zone.extraSeconds)} on a {slowZoneSeconds(zone.baselineSeconds)} run · since {slowZoneDate(zone.since)}</small></div>
  </li>;
}
export const slowZoneAttribution = 'Slow zones are estimated from weekday daytime run times by Transit Lab (transitlab.nyc, CC BY 4.0), built from MTA data. Not an official MTA speed restriction list; the slow section can be anywhere between the two stops.';
