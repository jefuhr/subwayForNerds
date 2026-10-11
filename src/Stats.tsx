import { useEffect, useState } from 'react';
import { api, base } from './platform';
import { getDeviceSettings } from './settings-store';
import type { Stats as StatsData } from '../shared/analytics';
import { themes } from './themes';
import './stats.css';
const labels: Record<string, string> = { favorite_add: 'Favorites added', favorite_remove: 'Favorites removed', direction: 'Direction filters', line: 'Line filters', reset: 'Filter resets', train_open: 'Train details opened', fleet_open: 'Fleet opens' };
const dateTime = (n: number) => new Date(n).toLocaleString('en-US', { timeZone: 'America/New_York' });
export default function Stats() {
  const [range, setRange] = useState('30d');
  const [data, setData] = useState<StatsData>();
  const [error, setError] = useState('');
  useEffect(() => { document.title = 'Public usage stats · Subways for Nerds'; const { theme } = getDeviceSettings().settings; document.documentElement.dataset.theme = themes.some(t => t.id === theme) ? theme : 'subway'; }, []);
  useEffect(() => {
    const controller = new AbortController(); let busy = false;
    setData(undefined);
    const load = async () => {
      if (document.hidden || busy) return;
      if (!navigator.onLine) { setError('Offline · statistics are unavailable until you reconnect.'); return; }
      busy = true;
      try { const result = await api<StatsData>('stats?range=' + range, controller.signal); if (!controller.signal.aborted) { setData(result); setError(''); } }
      catch { if (!controller.signal.aborted) setError('Statistics are temporarily unavailable. Retrying automatically.'); }
      finally { busy = false; }
    };
    void load(); const timer = setInterval(load, 60000);
    document.addEventListener('visibilitychange', load); window.addEventListener('online', load); window.addEventListener('offline', load);
    return () => { controller.abort(); clearInterval(timer); document.removeEventListener('visibilitychange', load); window.removeEventListener('online', load); window.removeEventListener('offline', load); };
  }, [range]);
  const maximum = Math.max(1, ...(data?.daily.map(d => d.visits) || []));
  return <main className="stats-page">
    <a href={base}>← Return to departures</a>
    <h1>Public usage stats</h1>
    <p>Visits are browsing sessions, ending after 30 minutes without recorded activity. Unique and returning browser counts are estimates, not people. Returning browsers have an earlier session within retained history.</p>
    <label>Period <select value={range} onChange={e => setRange(e.target.value)}><option value="today">Today</option><option value="7d">7 days</option><option value="30d">30 days</option><option value="365d">One year</option></select></label>
    <p className="fine-print">Dates use America/New_York. This page does not count as rider traffic.</p>
    {error && <p role="status" className="notice">{error}{data ? ' Showing the last loaded totals.' : ''}</p>}
    {!data && !error && <p role="status">Loading statistics…</p>}
    {data && <>
      <div className="stats-totals">{[['Visits', data.visits], ['Unique browsers (estimated)', data.browsers], ['Returning browsers (estimated)', data.returning], ['Station views', data.views]].map(([label, value]) => <article key={label}><strong>{Number(value).toLocaleString()}</strong><span>{label}</span></article>)}</div>
      {!data.visits && !data.views && <p>No traffic has been recorded for this period yet.</p>}
      <section><h2>Daily traffic</h2><p id="chart-summary">{data.visits.toLocaleString()} visits and {data.views.toLocaleString()} station views over {data.daily.length} {data.daily.length === 1 ? 'day' : 'days'}. Bar heights show visits. Exact totals are in the table below.</p>
        <div className="stats-chart" role="img" aria-labelledby="chart-summary">{data.daily.map(d => <div key={d.date} style={{ height: `${Math.max(1, d.visits / maximum * 100)}%` }} title={`${d.date}: ${d.visits} visits, ${d.views} station views`} />)}</div>
        <details><summary>Daily traffic table</summary><div className="stats-table-scroll"><table><thead><tr><th scope="col">Date</th><th scope="col">Visits</th><th scope="col">Station views</th></tr></thead><tbody>{data.daily.map(d => <tr key={d.date}><th scope="row">{d.date}</th><td>{d.visits}</td><td>{d.views}</td></tr>)}</tbody></table></div></details>
      </section>
      <div className="stats-breakdowns"><Breakdown title="Popular stations" rows={data.stations} /><Breakdown title="Devices (visits)" rows={data.devices} /><Breakdown title="Referring hosts (visits)" rows={data.referrers} /><Breakdown title="Interactions" rows={data.interactions.map(r => ({ ...r, label: labels[r.label] || r.label }))} /></div>
      <p className="fine-print">Collection started {dateTime(data.collectedSince)} · Last updated {dateTime(data.updatedAt)} (New York time). Refreshes every 60 seconds while visible.</p>
    </>}
    <p className="fine-print">First-party analytics use a random locally stored browser ID and retain one year of activity. We record station views and control actions, coarse device categories, and referring hostnames. We do not collect location, search text, full referrer URLs, raw IP addresses, or raw user-agent strings in analytics. Only aggregate totals are public. No historical backfill.</p>
  </main>;
}
function Breakdown({ title, rows }: { title: string; rows: { label: string; count: number }[] }) {
  return <section><h2>{title}</h2>{rows.length ? <table><thead><tr><th scope="col">{title}</th><th scope="col">Total</th></tr></thead><tbody>{rows.map(r => <tr key={r.label}><th scope="row">{r.label}</th><td>{r.count.toLocaleString()}</td></tr>)}</tbody></table> : <p>No activity recorded.</p>}</section>;
}
