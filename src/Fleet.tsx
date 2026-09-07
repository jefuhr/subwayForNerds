import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { ArrowLeft, ChevronRight, Search } from 'lucide-react';
import type { FleetCar, FleetDetail, FleetPage } from '../shared/fleet';
import { ageLabel, clockTime } from '../shared/display';
import { api } from './platform';
import Modal from './Modal';

function useFleetData<T>(path: string) {
  const [data, setData] = useState<T>(), [error, setError] = useState('');
  useEffect(() => {
    const controller = new AbortController(); let busy = false;
    setData(undefined); setError('');
    const refresh = async () => {
      if (busy) return; busy = true;
      try { const next = await api<T>(path, controller.signal); if (!controller.signal.aborted) { setData(next); setError(''); } }
      catch { if (!controller.signal.aborted) setError('Fleet data unavailable. Previous reports are not current; departures are unaffected.'); }
      finally { busy = false; }
    };
    void refresh(); const timer = setInterval(() => { if (!document.hidden) void refresh(); }, 10000);
    return () => { controller.abort(); clearInterval(timer); };
  }, [path]);
  return { data, error };
}
const observedNow = (car: FleetCar, now: number, failed = false) => !failed && car.reporting && !!car.last && now - car.last.timestamp <= 90;
function CarReport({ car, now, failed }: { car: FleetCar; now: number; failed?: boolean }) {
  return <><span className={observedNow(car, now, failed) ? 'fleet-live' : 'muted'}>{observedNow(car, now, failed) ? `${car.last!.route} · currently reporting` : car.last ? 'Last seen' : 'Never observed'}</span>
    <span>{car.last?.location || 'No location report collected'}</span>
    {car.last && <small>Position {ageLabel(car.last.locationTimestamp, now)} · association {ageLabel(car.last.timestamp, now)}</small>}
    {!observedNow(car, now, failed) && <small>Est. home yard: {car.estimatedYard?.name || 'unknown'}</small>}</>;
}
export default function Fleet({ close, now, initialId, station, trip }: { close: () => void; now: number; initialId?: string; station: (id: string) => void; trip: (key: string) => void }) {
  const [selected, setSelected] = useState<{ id: string; kind: string } | undefined>(initialId ? { id: initialId, kind: 'cars' } : undefined);
  const panel = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => { if (panel.current) panel.current.scrollTop = 0; }, [selected]);
  const [filters, setFilters] = useState({ q: '', category: '', status: '', view: 'groups', equipment: '', route: '', yard: '', retired: '', page: '1' });
  const update = (key: string, value: string) => { if (key === 'page' && panel.current) panel.current.scrollTop = 0; setFilters(f => ({ ...f, [key]: value, ...(key !== 'page' ? { page: '1' } : {}) })); };
  return <Modal fullscreen title={selected ? 'Car & consist details' : 'The fleet'} eyebrow="EVERY CAR HAS A HISTORY" close={close}>
    <div className="fleet-panel" ref={panel}>
      {selected ? <FleetDetails selection={selected} now={now} back={() => setSelected(undefined)} select={setSelected} station={station} trip={trip} /> : <>
        <div className="station-search-input"><Search size={18} /><input aria-label="Search fleet" placeholder="Car number, alias, or equipment…" value={filters.q} onChange={e => update('q', e.target.value)} autoComplete="off" autoCorrect="off" spellCheck={false} /></div>
        <div className="fleet-filters">
          <select aria-label="Fleet grouping" value={filters.view} onChange={e => update('view', e.target.value)}><option value="groups">Grouped consists</option><option value="cars">Individual cars</option></select>
          <select aria-label="Fleet category" value={filters.category} onChange={e => update('category', e.target.value)}><option value="">All categories</option>{['passenger', 'work', 'museum', 'sir'].map(c => <option key={c} value={c}>{c === 'sir' ? 'SIR' : c}</option>)}</select>
          <select aria-label="Reporting status" value={filters.status} onChange={e => update('status', e.target.value)}><option value="">Any reporting status</option><option value="reporting">Currently reporting</option><option value="unreported">Not currently reporting</option></select>
          <FleetFacetFilters filters={filters} update={update} />
        </div>
        <FleetResults filters={filters} now={now} select={setSelected} page={p => update('page', String(p))} />
      </>}
    </div>
  </Modal>;
}
function FleetFacetFilters({ filters, update }: { filters: Record<string, string>; update: (key: string, value: string) => void }) {
  const { data } = useFleetData<FleetPage>('fleet?view=cars&page=1');
  const options = data?.facets;
  return <details><summary>More filters</summary><div className="fleet-filters"><select aria-label="Filter fleet equipment" value={filters.equipment} onChange={e => update('equipment', e.target.value)}><option value="">All car types</option>{(options?.equipment || []).map(v => <option key={v} value={v}>{v}</option>)}<option value="unknown">Unknown / unreported</option></select><select aria-label="Filter fleet route" value={filters.route} onChange={e => update('route', e.target.value)}><option value="">All routes</option>{(options?.route || []).map(v => <option key={v} value={v}>{v}</option>)}<option value="unknown">Unknown / unreported</option></select><select aria-label="Filter fleet yard" value={filters.yard} onChange={e => update('yard', e.target.value)}><option value="">All yards</option>{(options?.yard || []).map(v => <option key={v} value={v}>{v}</option>)}<option value="unknown">Unknown / unreported</option></select><label><input type="checkbox" checked={filters.retired === 'true'} onChange={e => update('retired', e.target.checked ? 'true' : '')} />Include retired / scrapped</label></div></details>;
}
function FleetResults({ filters, now, select, page }: { filters: Record<string, string>; now: number; select: (s: { id: string; kind: string }) => void; page: (p: number) => void }) {
  const [settled, setSettled] = useState(filters);
  useEffect(() => { const timer = setTimeout(() => setSettled(filters), 180); return () => clearTimeout(timer); }, [filters]);
  const { data, error } = useFleetData<FleetPage>('fleet?' + new URLSearchParams(settled));
  return <>{error && <p className="notice" role="status">{error}</p>}{!data && !error && <p className="empty">Loading fleet inventory…</p>}
    {data && <>
      <p className="fine-print">{data.total.toLocaleString()} matching {filters.view === 'cars' ? 'cars' : 'groups'} · missing from a feed does not mean inactive</p>
      <div className="fleet-results">{data.rows.map(row => <button key={row.id} className="fleet-row" onClick={() => select({ id: row.id, kind: row.kind === 'car' ? 'cars' : 'consists' })}>
        <span className="fleet-numbers"><strong>{row.cars.map(c => c.number).join(' · ')}</strong><small>{[...new Set(row.cars.map(c => c.equipment))].join(' / ')} · {row.cars.length} {row.cars.length === 1 ? 'car' : 'cars'}{row.id.startsWith('set:') ? ' · documented link' : ''}</small></span>
        <span className="fleet-position"><CarReport car={row.cars[0]} now={now} failed={!!error} /></span><ChevronRight size={16} />
      </button>)}{!data.rows.length && <p className="empty">No documented cars match these filters.</p>}</div>
      <div className="fleet-pagination"><button className="text-button" disabled={data.page <= 1} onClick={() => page(data.page - 1)}>Previous</button><span>{data.page} / {data.pages}</span><button className="text-button" disabled={data.page >= data.pages} onClick={() => page(data.page + 1)}>Next</button></div>
      <details className="raw-details"><summary>Coverage & sources</summary>{data.coverage.map(c => <p key={c.category}>{c.category}: {c.count.toLocaleString()} cars. {c.note}</p>)}{data.sources.map((s, i) => <p key={i}><a href={s.url} target="_blank" rel="noreferrer">{s.date}</a> · {s.note}</p>)}<p>“All” covers the imported inventory, not every vehicle ever built. Collection starts when this server runs; historical movements cannot be reconstructed from a missing feed.</p></details>
    </>}
  </>;
}
function FleetDetails({ selection, now, back, select, station, trip }: { selection: { id: string; kind: string }; now: number; back: () => void; select: (s: { id: string; kind: string }) => void; station: (id: string) => void; trip: (key: string) => void }) {
  const { data, error } = useFleetData<FleetDetail>(`fleet/${selection.kind}/${encodeURIComponent(selection.id)}`);
  const current = data?.cars.find(c => observedNow(c, now, !!error) && (!selection.id.startsWith('observed:') || c.last?.consistId === selection.id))?.last;
  const next = current?.next;
  return <><button className="text-button" onClick={back}><ArrowLeft size={16} />Back to fleet</button>
    {error && <p className="notice">{error}</p>}{!data && !error && <p className="empty">Loading car history…</p>}
    {data && <>
      <section className="fleet-next"><strong>{next && (next.time == null || next.time >= now) ? `Next stop: ${next.name}` : 'Next stop unavailable'}</strong>{next && (next.time == null || next.time >= now) && <span>{clockTime(next.time)} estimated · {current!.route}{next.stationId && <button className="text-button" onClick={() => station(next.stationId!)}>Open station board</button>}</span>}{current && <button className="text-button" onClick={() => trip(current.tripKey)}>Open live train details</button>}</section>
      <p className="fine-print">Reported order does not establish the leading end. Historical formations are not confirmed current links.</p>
      {data.cars.map(car => <section className="fleet-car" key={car.id}>
        <h3><button className="text-button" onClick={() => select({ id: car.id, kind: 'cars' })}>{car.number} · {car.equipment}</button></h3>
        <CarReport car={car} now={now} failed={!!error} />
        <p className="fine-print">Roster: {car.lifecycle}{car.aliases.length ? ` · aliases ${car.aliases.join(', ')}` : ''}</p>
        {car.facts && <dl className="fact-grid">{Object.entries(car.facts).map(([key, value]) => <div key={key}><dt>{key.replaceAll('_', ' ')}</dt><dd>{value}</dd></div>)}</dl>}
        {car.last && selection.kind === 'cars' && <button className="text-button" onClick={() => select({ id: car.last!.consistId, kind: 'consists' })}>{observedNow(car, now, !!error) ? 'Current' : 'Last observed'} consist</button>}
        {car.estimatedYard && <p className="fine-print">Est. home yard: {car.estimatedYard.name} · <a href={car.estimatedYard.url} target="_blank" rel="noreferrer">{car.estimatedYard.date}</a> · {car.estimatedYard.note}</p>}
        {car.conflicts?.map(c => <p className="notice" key={c}>{c}</p>)}
        {car.evidence.map((e, i) => <p className="fine-print" key={i}><a href={e.url} target="_blank" rel="noreferrer">Source · {e.date}</a> · {e.note}</p>)}
      </section>)}
      <h3>Observed changes · last 30 days</h3><p className="fine-print">Latest 200 changes. Times are observation times, not inferred movement times.</p>
      {!data.history.length && <p className="empty">No movement history collected for this period.</p>}
      <ol className="fleet-history">{data.history.map((h, i) => <li key={i}><strong>{h.route} · {h.location}</strong><span>{new Date(h.timestamp * 1000).toLocaleString('en-US', { timeZone: 'America/New_York' })} ET</span><small>Cars {h.cars.map(id => id.split(':').at(-1)).join(' · ')}</small></li>)}</ol>
    </>}
  </>;
}
