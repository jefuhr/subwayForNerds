import { Clock3, TriangleAlert } from 'lucide-react';
import type { TripChange } from '../shared/types';
import { changeStale } from '../shared/changes';
import { ageLabel } from '../shared/display';
import './changes.css';

export function ChangeLabels({ changes = [], now, cached = false, id, iconsOnly = false }: { changes?: TripChange[]; now: number; cached?: boolean; id?: string; iconsOnly?: boolean }) {
  if (!changes.length) return null;
  return <span id={id} className={`change-labels${iconsOnly ? ' change-icons' : ''}`}>{(iconsOnly ? changes : changes.slice(0,2)).map(c => {
    const stale = changeStale(c, now, cached);
    const Icon = c.classification === 'scheduled' || stale ? Clock3 : TriangleAlert;
    return <span key={c.id} className={`change-label change-${stale && !iconsOnly ? 'stale' : c.classification}`} title={`${stale ? 'Last known · ' : ''}${c.description || c.label}`} aria-label={iconsOnly ? `${c.classification} · ${stale ? 'last known · ' : ''}${c.label}` : undefined}>
      <Icon size={iconsOnly ? 16 : 12} aria-hidden="true" />{!iconsOnly && <>{stale ? 'last known · ' : ''}{c.label}{c.advisory ? ' · advisory' : ''}</>}
    </span>;
  })}{!iconsOnly && changes.length > 2 && <span className="change-label change-more" title="Open train details for all changes">+{changes.length-2}</span>}</span>;
}
export function ChangeDetails({ changes = [], now }: { changes?: TripChange[]; now: number }) {
  if (!changes.length) return null;
  return <section className="change-details" aria-label="Service changes"><h3>Different from normal</h3>
    <p className="fine-print">Compared with weekday daytime service. Scheduled variations are distinct from disruptions; advisory notices may not affect every train.</p>
    {changes.map(c => <details key={c.id} className="change-explanation"><summary><ChangeLabels changes={[c]} now={now} /></summary>
      <p>{c.description}</p>
      <small>{c.classification === 'unplanned' ? 'Unplanned disruption' : c.classification === 'planned' ? 'Planned change' : c.classification === 'scheduled' ? 'Scheduled variation' : 'Cause not established'} · {c.evidence.map(e => `${e.source} · ${ageLabel(e.timestamp,now)}${e.unavailable ? ' · unavailable' : ''}`).join(' / ')}</small>
    </details>)}
  </section>;
}
