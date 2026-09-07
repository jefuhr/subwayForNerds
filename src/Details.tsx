import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { AlertTriangle, ArrowUpRight, Accessibility, Clock3 } from 'lucide-react';
import type { Board, StationContext, Train, StopPrediction, TransferResult } from '../shared/types';
import { ageLabel, clockTime, freshness } from '../shared/display';
import { api } from './platform';
import Modal from './Modal';
import { currentConsist } from '../shared/consist';
import { ChangeDetails, ChangeLabels } from './Changes';
import { changesAhead } from '../shared/changes';

export function TrainDetail({ tripKey, close, now, openFleet }: { tripKey: string; close: () => void; now: number; openFleet?: (id?: string) => void }) {
  const [data, setData] = useState<{ train: Train; raw: unknown }>();
  const [error, setError] = useState('');
  const [selected, setSelected] = useState<StopPrediction>();
  const trainView = useRef<HTMLDivElement>(null), savedScroll = useRef(0);
  useLayoutEffect(() => { const dialog = trainView.current?.closest('dialog'); if (dialog) dialog.scrollTop = selected ? 0 : savedScroll.current; }, [selected]);
  useEffect(() => {
    const controller = new AbortController();
    const update = () => api<{ train: Train; raw: unknown }>('trips?key=' + encodeURIComponent(tripKey), controller.signal).then(value => { setData(value); setError(''); }).catch(e => { if (!controller.signal.aborted) setError(e.message); });
    void update(); const timer = setInterval(() => { if (!document.hidden) void update(); }, 10000);
    return () => { controller.abort(); clearInterval(timer); };
  }, [tripKey]);
  const train = data?.train;
  return <Modal title={train ? `${train.route} → ${train.destination}` : 'Train details'} eyebrow="THE WHOLE PICTURE" close={close}>
    {error && <p className="notice"><AlertTriangle size={16} />{error}</p>}
    {!train && !error && <p className="empty">Loading train details…</p>}
    {train && <div ref={trainView} hidden={!!selected}>
      <div className="detail-summary"><span className={'status-pill ' + freshness(train.timestamp, now)}>{freshness(train.timestamp, now)} · {ageLabel(train.timestamp, now)}</span><span className="muted">{train.direction.toLowerCase()} · {train.stops.length} reported stops</span></div>
      <dl className="fact-grid">
        <div><dt>Operations ID</dt><dd>{train.trainId || 'Not reported'}</dd></div>
        <div><dt>Assignment</dt><dd>{train.assigned === true ? 'Assigned to a train' : train.assigned === false ? 'Not yet assigned' : 'Not reported'}</dd></div>
        <div><dt>Service date</dt><dd>{train.serviceDate || 'Not reported'}</dd></div>
        <div><dt>Position report</dt><dd>{train.position ? `${train.position.name} · ${ageLabel(train.position.timestamp, now)}` : 'Not reported'}</dd></div>
      </dl>
      <section className="consist-detail">
        <div className="section-label">CAR NUMBERS <span>{currentConsist(train.consist, now) ? `Helium · reported ${ageLabel(train.consist.updatedAt, now)}` : 'Not currently available'}</span></div>
        {currentConsist(train.consist, now) && <><ol className="consist-cars">{train.consist.cars.map((car, i) => <li key={i}><button className="car-link" onClick={() => openFleet?.(car.type ? `${train.feed === 'gtfs-si' ? 'sir' : 'nyct'}:${/^R160[AB]?$/.test(car.type) ? 'R160' : car.type}:${car.number}` : undefined)}><strong>{car.number}</strong>{car.type && <small>{car.type}</small>}</button></li>)}</ol><p className="fine-print">Tap a car for its fleet history. Reported order does not confirm the front of the train.</p></>}
      </section>
      {train.alerts.map(a => <p key={a} className="notice"><AlertTriangle size={16} />{a}</p>)}
      <ChangeDetails changes={changesAhead(train.changes, 0)} now={now} />
      <div className="section-label">REMAINING STOPPING PATTERN <span>Arrival / departure · Eastern</span></div>
      <ol className="stop-sequence">{train.stops.map((s, i) => <li key={s.id + i} className={s.relationship === 'SKIPPED' ? 'skipped' : ''}>
        <button className="stop-link" disabled={s.relationship === 'SKIPPED' || !s.stationId || (s.arrival ?? s.departure ?? Infinity) < now} aria-label={`Transfers at ${s.name}`} onClick={() => { savedScroll.current = trainView.current?.closest('dialog')?.scrollTop || 0; setSelected(s); }}>
        <span className="stop-dot" /><div><strong>{s.name}</strong><small>{s.id}{s.relationship === 'SKIPPED' ? ' · skipped' : ''}{s.scheduledTrack ? ` · scheduled track ${s.scheduledTrack}` : ''}{s.actualTrack ? ` · reported track ${s.actualTrack}` : ''}</small><ChangeLabels changes={s.changes} now={now} /></div>
        <span className="stop-time">{clockTime(s.arrival)}{s.departure && s.departure !== s.arrival && <small>dep {clockTime(s.departure)}</small>}</span>
        </button>
      </li>)}</ol>
      <p className="fine-print">Stopping patterns reflect the remaining feed predictions. Track fields describe each stop; a future track value is not the train’s current position. Operations IDs identify trips, not physical cars.</p>
      {train.scheduledPattern && <details className="raw-details"><summary>Matching scheduled pattern · {train.scheduledPattern.headsign}</summary><p className="fine-print">Shape {train.scheduledPattern.shape} · {train.scheduledPattern.source === 'gtfs_supplemented' ? 'Supplemented GTFS' : 'Regular GTFS'}. Static context only; live predictions above take precedence.</p><p className="fine-print">{train.scheduledPattern.stops.join(' → ')}</p></details>}
      <details className="raw-details"><summary>Decoded feed & identifiers</summary><pre>{JSON.stringify(data, null, 2)}</pre></details>
    </div>}
    {selected && <TransferView tripKey={tripKey} stop={selected} now={now} back={() => setSelected(undefined)} />}
  </Modal>;
}
function TransferView({ tripKey, stop, now, back }: { tripKey: string; stop: StopPrediction; now: number; back: () => void }) {
  const [data, setData] = useState<TransferResult>(), [error, setError] = useState('');
  useEffect(() => {
    const controller = new AbortController(); let busy = false;
    const query = new URLSearchParams({ key: tripKey, stopId: stop.id, ...(stop.sequence == null ? {} : { sequence: String(stop.sequence) }) });
    const refresh = async () => {
      if (busy) return; busy = true;
      try { const result = await api<TransferResult>('trips/transfers?' + query, controller.signal); if (!controller.signal.aborted) { setData(result); setError(''); } }
      catch { if (!controller.signal.aborted) setError('Transfer predictions unavailable. Reconnect for current estimates.'); }
      finally { busy = false; }
    };
    void refresh(); const timer = setInterval(() => { if (!document.hidden) void refresh(); }, 10000);
    return () => { controller.abort(); clearInterval(timer); };
  }, [tripKey, stop.id, stop.sequence]);
  const groups = new Map<string, TransferResult['connections']>();
  const stale = !!data && (freshness(data.originTimestamp, now) !== 'live' || (data.arrival != null && data.arrival < now));
  for (const d of error || stale ? [] : (data?.connections || []).filter(d => freshness(d.timestamp, now) === 'live' && d.time != null && d.time >= now)) { const key = [d.route, d.direction, d.area].join('|'); const a = groups.get(key) || []; a.push(d); groups.set(key, a); }
  return <section className="transfer-view"><button className="text-button" onClick={back}>← Back to train</button><h3>Transfers at {stop.name}</h3>
    {error && <p className="notice">{error}</p>}{!data && !error && <p className="empty">Checking connecting departures…</p>}
    {data && <><p>Your train: {clockTime(data.arrival)} estimated {data.basis}{data.basis === 'departure' ? ' (arrival unavailable)' : ''} · updated {ageLabel(data.originTimestamp, now)}</p>{stale && !data.message && <p className="notice">Predictions are stale or the arrival estimate has passed. Awaiting an update.</p>}<p className="fine-print">Next 30 minutes · raw time gaps, no walking allowance. Boarding areas may require stairs, passageways, or different platform access. Connections are not guaranteed.</p>
      {data.message && <p className="notice">{data.message}</p>}
      {[...groups.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([key, connections]) => <section className="transfer-group" key={key}><h4>{connections[0].route} · {connections[0].area}</h4>{connections.sort((a, b) => a.time! - b.time!).map(d => <div className="transfer-row" key={d.key}><span><strong>{d.destination}</strong><small>{d.actualTrack ? `Reported track ${d.actualTrack}` : d.scheduledTrack ? `Scheduled track ${d.scheduledTrack}` : 'Track not reported'}</small><ChangeLabels changes={d.changes} now={now} /></span><span><strong>{clockTime(d.time)}</strong><small>{d.gap < 60 ? '<1 min' : `${Math.floor(d.gap / 60)} min`} after arrival · {d.basis}{d.basis === 'arrival' ? ' fallback' : ''}</small></span></div>)}</section>)}
      <details className="raw-details"><summary>Prediction sources</summary>{data.sources.map(s => <p key={s.id}>{s.id} · {clockTime(s.timestamp)}{s.error ? ' · unavailable' : ''}</p>)}</details>
    </>}
  </section>;
}
export function ContextDetail({ board, close, now }: { board: Board; close: () => void; now: number }) {
  const [context, setContext] = useState<StationContext>();
  const [error, setError] = useState('');
  useEffect(() => {
    const controller = new AbortController();
    const refresh = () => api<StationContext>(`stations/${board.station.id}/context`, controller.signal).then(setContext).catch(e => { if (!controller.signal.aborted) setError(e.message); });
    void refresh(); const timer = setInterval(() => { if (!document.hidden) void refresh(); }, 60000);
    return () => { controller.abort(); clearInterval(timer); };
  }, [board.station.id]);
  const outageState = context?.sources.find(s => s.id === 'outages');
  const equipmentState = context?.sources.find(s => s.id === 'equipment');
  const outageFresh = !!outageState?.timestamp && !outageState.error && now - (outageState.fetchedAt || 0) <= 120;
  return <Modal title={board.station.name} eyebrow="STATION FIELD NOTES" close={close}>
    {board.station.parts.map(p => <section className="context-section" key={p.id}><h3>{p.line}</h3><p><Accessibility size={16} /> {p.ada === '1' ? 'ADA accessible' : p.ada === '2' ? 'Partially accessible' : 'Not ADA accessible'}{p.adaNotes ? ` · ${p.adaNotes}` : ''}</p><div className="muted">{p.id} · {p.north} / {p.south}</div></section>)}
    {error && <p className="notice">{error}</p>}
    {!context && !error && <p className="empty">Loading station context…</p>}
    {context && <>
      <div className="section-label">ELEVATORS & ESCALATORS <span>{ageLabel(outageState?.fetchedAt, now)}</span></div>
      {!outageFresh && <p className="notice"><AlertTriangle size={16} />Current equipment status is unavailable or stale</p>}
      {context.equipment.map(e => {
        const reports = context.outages.filter(o => (o.equipment || o.equipmentno) === e.equipmentno);
        const current = reports.filter(o => o.isupcomingoutage !== 'Y');
        return <section className="equipment" key={e.equipmentno}><div><strong>{e.equipmentno} · {e.shortdescription || e.serving}</strong><span className={'status-pill ' + (current.length ? 'stale' : 'neutral')}>{current.length ? 'Outage reported' : outageFresh && equipmentState?.fetchedAt ? e.isactive === 'N' ? 'Inactive' : 'No current outage reported' : 'Status unknown'}</span></div><p>{e.serving}</p>
          {reports.map((o, i) => <p className="outage-note" key={i}>{o.isupcomingoutage === 'Y' ? 'Upcoming: ' : ''}{o.reason} · {o.outagedate} → {o.estimatedreturntoservice || 'Return time unknown'}</p>)}
          {reports.length > 0 && e.alternativeroute && <details><summary>Travel alternative</summary><p>{e.alternativeroute}</p></details>}
        </section>;
      })}
      {!context.equipment.length && <p className="empty">{equipmentState?.fetchedAt ? 'No equipment records matched this station' : 'Equipment feed not yet available'}</p>}
      <div className="section-label">ENTRANCES <span>{context.entrances.length} records</span></div>
      <p className="fine-print">Entrance coordinates are published locations, not walking directions.</p>
      {context.entrances.map((e, i) => <div className="entrance" key={i}><div><strong>{e.constituent_station_name} · {e.entrance_type}</strong><small>Entry {e.entry_allowed?.toLowerCase()} · exit {e.exit_allowed?.toLowerCase()}</small></div><a href={`https://www.openstreetmap.org/?mlat=${encodeURIComponent(e.entrance_latitude)}&mlon=${encodeURIComponent(e.entrance_longitude)}#map=19/${encodeURIComponent(e.entrance_latitude)}/${encodeURIComponent(e.entrance_longitude)}`} target="_blank" rel="noreferrer" aria-label={`View entrance ${i + 1} on map`}><ArrowUpRight size={18} /></a></div>)}
      {!context.entrances.length && <p className="empty">No entrance data available</p>}
      <details className="raw-details"><summary><Clock3 size={14} /> Source freshness</summary>{context.sources.map(s => <p key={s.id}>{s.id} · fetched {ageLabel(s.fetchedAt, now)}{s.error ? ' · unavailable' : ''}</p>)}</details>
    </>}
  </Modal>;
}
