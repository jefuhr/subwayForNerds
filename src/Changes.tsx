import { Clock3, TriangleAlert } from 'lucide-react';
import type { TripChange } from '../shared/types';
import { changeStale } from '../shared/changes';
import { ageLabel } from '../shared/display';
import './changes.css';

export function ChangeLabels({ changes = [], now, cached = false, id }: { changes?: TripChange[]; now: number; cached?: boolean; id?: string }) {
  if (!changes.length) return null;
  return <span id={id} className="change-labels">{changes.slice(0,2).map(c => {
    const stale = changeStale(c, now, cached);
    const Icon = c.classification === 'scheduled' || stale ? Clock3 : TriangleAlert;
    return <span key={c.id} className={`change-label change-${stale ? 'stale' : c.classification}`} title={c.description || c.label}>
      <Icon size={12} aria-hidden="true" />{stale ? 'last known · ' : ''}{c.label}{c.advisory ? ' · advisory' : ''}
    </span>;
  })}{changes.length > 2 && <span className="change-label change-more" title="Open train details for all changes">+{changes.length-2}</span>}</span>;
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
