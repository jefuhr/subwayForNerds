import { lazy, Suspense, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { ArrowDown, ArrowRight, ArrowUp, ArrowUpRight, ArrowLeftRight, Check, ChevronDown, ChevronRight, Clock3, Crosshair, ExternalLink, Info, Layers3, MapPin, Palette, Radio, RefreshCw, Search, SlidersHorizontal, Star, TrainFront, TriangleAlert, X } from 'lucide-react';
import type { Board, Departure, Station } from '../shared/types';
import { ageLabel, boardable, clockTime, countdown, distanceMeters, freshness } from '../shared/display';
import { api, locate, storage } from './platform';
import { useBoard } from './useBoard';
import { themes } from './themes';
import { currentConsist } from '../shared/consist';
import Modal from './Modal';
import { ChangeLabels } from './Changes';

const TrainDetail = lazy(() => import('./Details').then(m => ({ default: m.TrainDetail })));
const Fleet = lazy(() => import('./Fleet'));
const ContextDetail = lazy(() => import('./Details').then(m => ({ default: m.ContextDetail })));
const boroughs: Record<string, string> = { M: 'Manhattan', B: 'Brooklyn', Bk: 'Brooklyn', Bx: 'Bronx', Q: 'Queens', SI: 'Staten Island' };
const quickStations = ['602', '617', '611', '607'];
const displayRoute = (route: string) => ({ GS: 'S', FS: 'S', H: 'S', SI: 'SIR' })[route] || route;
const routeColor = (route: string) => /^[123]$/.test(route) ? 'red' : /^[456]/.test(route) ? 'green' : /^7/.test(route) ? 'purple' : /^[ACE]$/.test(route) ? 'blue' : /^(B|D|F|FX|M)$/.test(route) ? 'orange' : /^[NQRW]$/.test(route) ? 'yellow' : route === 'G' ? 'lime' : /^[JZ]$/.test(route) ? 'brown' : 'gray';
export function Bullet({ route, small = false }: { route: string; small?: boolean }) {
  return <span className={`route-bullet ${routeColor(route)} ${small ? 'small' : ''}`} title={route}>{displayRoute(route)}</span>;
}
function readStation() {
  return new URLSearchParams(location.search).get('station') || storage.get('station', '602');
}
export default function App() {
  const [stationId, setStationId] = useState(readStation);
  const [stations, setStations] = useState<Station[]>(() => storage.get('stations', []));
  const [catalogError, setCatalogError] = useState('');
  const [favorites, setFavorites] = useState<string[]>(() => storage.get('favorites', []));
  const [theme, setTheme] = useState(() => storage.get('theme', 'subway'));
  const [panel, setPanel] = useState<'stations' | 'themes' | 'alerts' | 'context' | 'filters' | 'direction' | 'fleet' | null>(null);
  const [tripKey, setTripKey] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [nearby, setNearby] = useState<{ latitude: number; longitude: number }>();
  const [locationState, setLocationState] = useState('');
  const [locating, setLocating] = useState(false);
  const [direction, setDirection] = useState(() => storage.get('direction', 'ALL'));
  const [routes, setRoutes] = useState<string[]>(() => storage.get('routes', []));
  const [fleetId, setFleetId] = useState<string>();
  const openFleet = (id?: string) => { setTripKey(null); setFleetId(id); setPanel('fleet'); };
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  const autoOpenedFavorite = useRef(false);
  const { board, cached, error, refresh } = useBoard(stationId);
  useLayoutEffect(() => {
    if (board?.departures.length && !performance.getEntriesByName('sfn-board-visible').length) performance.mark('sfn-board-visible');
  }, [board]);
  const station = board?.station || stations.find(s => s.id === stationId);
  useEffect(() => { const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000); return () => clearInterval(timer); }, []);
  useEffect(() => {
    const controller = new AbortController();
    const load = () => api<Station[]>('stations', controller.signal).then(data => { setStations(data); storage.set('stations', data); setCatalogError(''); }).catch(() => { if (!controller.signal.aborted) setCatalogError('Station catalog unavailable. Reconnect to load every station.'); });
    void load(); window.addEventListener('online', load);
    return () => { controller.abort(); window.removeEventListener('online', load); };
  }, []);
  useEffect(() => { const pop = () => { setStationId(readStation()); }; window.addEventListener('popstate', pop); return () => window.removeEventListener('popstate', pop); }, []);
  useEffect(() => { const selected = themes.some(t => t.id === theme) ? theme : 'subway'; document.documentElement.dataset.theme = selected; storage.set('theme', selected); }, [theme]);
  useEffect(() => { storage.set('favorites', favorites); }, [favorites]);
  useEffect(() => { storage.set('direction', direction); storage.set('routes', routes); }, [direction, routes]);
  useEffect(() => { document.title = station ? `${station.name} · Subways for Nerds` : 'Subways for Nerds'; }, [station?.name]);
  const selectStation = (id: string) => {
    setStationId(id); storage.set('station', id); setTripKey(null); setPanel(null);
    const url = new URL(location.href); url.searchParams.set('station', id); history.pushState({}, '', url);
    window.scrollTo({ top: 0, behavior: 'instant' });
  };
  useEffect(() => {
    // A shared link is explicit. Otherwise, if the rider has favorites, use a
    // one-shot location fix to open the closest one on a fresh visit. If the
    // browser declines location, the saved station remains the instant fallback.
    if (autoOpenedFavorite.current || new URLSearchParams(location.search).has('station') || !favorites.length || !stations.length) return;
    autoOpenedFavorite.current = true;
    const favoriteStations = favorites.map(id => stations.find(s => s.id === id)).filter((s): s is Station => !!s);
    if (!favoriteStations.length) return;
    void locate().then(({ coords }) => {
      const closest = favoriteStations.reduce((best, candidate) => distanceMeters(coords.latitude, coords.longitude, candidate.lat, candidate.lon) < distanceMeters(coords.latitude, coords.longitude, best.lat, best.lon) ? candidate : best);
      if (closest.id === stationId) return;
      setStationId(closest.id);
      storage.set('station', closest.id);
      setTripKey(null);
      const url = new URL(location.href); url.searchParams.set('station', closest.id); history.replaceState({}, '', url);
    }).catch(() => { /* location is optional; keep the saved station */ });
  }, [favorites, stations, stationId]);
  const toggleFavorite = (id: string) => setFavorites(v => v.includes(id) ? v.filter(s => s !== id) : [...v, id]);
  const getNearby = async () => {
    setPanel('stations'); setQuery(''); setLocationState(''); setLocating(true);
    try { const fix = await locate(); setNearby(fix.coords); }
    catch (e) { setLocationState((e as GeolocationPositionError).code === 1 ? 'Location permission is off. You can still search for any station.' : 'Could not get your location. Search for a station or try again.'); }
    finally { setLocating(false); }
  };
  const matchingStations = useMemo(() => {
    const terms = query.toLowerCase().trim().split(/\s+/).filter(Boolean);
    return stations.filter(s => terms.every(t => `${s.name} ${boroughs[s.borough] || s.borough} ${s.routes.join(' ')} ${s.parts.map(p => p.line).join(' ')}`.toLowerCase().includes(t)))
      .map(s => ({ station: s, distance: nearby ? Math.min(...s.parts.map(p => distanceMeters(nearby.latitude, nearby.longitude, p.lat, p.lon))) : null }))
      .sort((a, b) => nearby ? (a.distance || 0) - (b.distance || 0) : Number(favorites.includes(b.station.id)) - Number(favorites.includes(a.station.id)) || a.station.name.localeCompare(b.station.name));
  }, [stations, query, nearby, favorites]);
  const availableRoutes = [...new Set([...(station?.routes || []), ...(board?.departures.map(d => d.route) || [])].map(displayRoute))];
  const visible = (board?.departures || []).filter(d => (direction === 'ALL' || d.direction === direction) && (!routes.length || routes.includes(displayRoute(d.route))) && !(freshness(d.timestamp, now) === 'live' && d.time != null && d.time < now - 30));
  const groups = new Map<string, Departure[]>();
  for (const d of visible) { const key = [d.direction, d.partId, d.actualTrack || d.scheduledTrack || '?'].join('|'); const rows = groups.get(key) || []; rows.push(d); groups.set(key, rows); }
  const sortedGroups = [...groups.values()].sort((a, b) => a[0].direction.localeCompare(b[0].direction) || a[0].partId.localeCompare(b[0].partId) || (a[0].actualTrack || a[0].scheduledTrack || '').localeCompare(b[0].actualTrack || b[0].scheduledTrack || ''));
  const trainSources = board?.sources.filter(s => s.id !== 'subway-alerts' && s.id !== 'helium') || [];
  const live = !cached && trainSources.some(s => freshness(s.timestamp, now) === 'live');
  const degraded = trainSources.some(s => freshness(s.timestamp, now) !== 'live' || s.error);
  const alertSource = board?.sources.find(s => s.id === 'subway-alerts');
  const alerts = board?.alerts || [];
  const favoriteStations = favorites.map(id => stations.find(s => s.id === id)).filter((s): s is Station => !!s);
  const shortcuts = quickStations.map(id => stations.find(s => s.id === id)).filter((s): s is Station => !!s);
  return <div className="app-shell">
    <a href="#departures" className="skip-link">Skip to departures</a>
    <aside className="sidebar">
      <a className="wordmark" href={import.meta.env.BASE_URL} aria-label="Subways for Nerds home"><span className="logo-mark"><img src={import.meta.env.BASE_URL + 'kitty.png'} alt="" width={128} height={128} /></span><span>subways<span className="wordmark-bottom">for nerds<span className="brand-dot">.</span></span></span></a>
      <div className="sidebar-tagline">Know the system.<br />Make your next move.</div>
      <button className="sidebar-search" onClick={() => { setPanel('stations'); setNearby(undefined); }}><Search size={17} /><span>Find a station</span><ChevronRight size={15} /></button>
      <button className="nearby-link" onClick={getNearby}><Crosshair size={16} /> Stations near me<ArrowUpRight size={14} /></button>
      <button className="nearby-link" onClick={() => openFleet()}><TrainFront size={16} />Fleet browser<ChevronRight size={14} /></button>
      <div className="sidebar-section-title"><span>YOUR STATIONS</span><Star size={13} /></div>
      <nav aria-label="Favorite stations">{favoriteStations.length ? favoriteStations.map(s => <StationShortcut key={s.id} station={s} selected={s.id === stationId} onClick={() => selectStation(s.id)} />) : <p className="sidebar-empty">Star a station to keep<br />your regular stops close.</p>}</nav>
      <div className="sidebar-section-title"><span>QUICK SWITCH</span><ArrowLeftRight size={13} /></div>
      <nav aria-label="Quick stations">{shortcuts.map(s => <StationShortcut key={s.id} station={s} selected={s.id === stationId} onClick={() => selectStation(s.id)} />)}</nav>
      <div className="sidebar-bottom"><div className="small-diagram" aria-hidden="true"><i /><i /><i /><i /><i /></div><p>A little more signal.<br />A lot less guesswork.</p><button className="theme-trigger" onClick={() => setPanel('themes')}><Palette size={17} /><span>{themes.find(t => t.id === theme)?.name || 'Subway console'}</span><ChevronRight size={14} /></button><a href="https://juliet.nyc" target="_blank" rel="noreferrer">a juliet.nyc project <ExternalLink size={12} /></a></div>
    </aside>
    <main className="main-panel">
      <header className="topbar"><div className="mobile-brand"><img src={import.meta.env.BASE_URL + 'kitty.png'} alt="" width={128} height={128} />subways for nerds<span>.</span></div><div className="desktop-breadcrumb"><span>THE SYSTEM</span><ChevronRight size={12} /><span>STATION BOARD</span></div><div className="topbar-right"><button className="text-button mobile-only" onClick={() => openFleet()} aria-label="Open fleet"><TrainFront size={16} />Fleet</button><span className="system-clock"><Clock3 size={13} />{clockTime(now)}<span> NYC</span></span><button className="icon-button mobile-only" onClick={() => setPanel('themes')} aria-label="Choose theme"><Palette size={18} /></button><a className="ferry-link" href="https://juliet.nyc/ferryTimesMobile/" target="_blank" rel="noreferrer">Taking the ferry? <ArrowUpRight size={13} /></a></div></header>
      <div className="board-content">
        <section className="station-heading"><div className="station-kicker"><span className="eyebrow">{boroughs[station?.borough || ''] || 'NEW YORK CITY'} / STATION {stationId}</span><span className={'status-pill ' + (live ? 'live' : 'stale')}><i />{live ? degraded ? 'PARTIAL LIVE DATA' : 'LIVE FEED' : cached && board ? 'CACHED BOARD' : board ? 'AWAITING LIVE DATA' : 'CONNECTING'}</span></div>
          <div className="station-title-row"><button className="station-name-button" onClick={() => { setPanel('stations'); setNearby(undefined); }}><h1>{station?.name || 'Your next train'}</h1><ChevronDown size={24} /></button><button className={'icon-button favorite-button ' + (favorites.includes(stationId) ? 'active' : '')} onClick={() => toggleFavorite(stationId)} aria-label={favorites.includes(stationId) ? 'Remove favorite station' : 'Favorite this station'} aria-pressed={favorites.includes(stationId)}><Star size={22} fill={favorites.includes(stationId) ? 'currentColor' : 'none'} /></button></div>
          <div className="station-meta"><div className="route-list">{(station?.routes || []).map(r => <Bullet route={r} small key={r} />)}</div><span className="station-description">{station?.parts.length ? `${station.parts.length} ${station.parts.length === 1 ? 'station' : 'connected stations'}` : 'Station-first. Always.'}</span><button className="text-button" onClick={() => board && setPanel('context')} disabled={!board}><Info size={14} />Station info<ArrowUpRight size={13} /></button><button className="nearby-mobile text-button" onClick={getNearby}><Crosshair size={16} />Nearby</button></div>
        </section>
        {(alerts.length > 0 || error || degraded) && <div className="notice-bar"><TriangleAlert size={16} /><span>{error || (alerts.length ? alerts[0].title : 'Some feeds are stale or unavailable. Check source ages below.')}</span>{alerts.length > 0 && <button onClick={() => setPanel('alerts')}>View {alerts.length > 1 ? `${alerts.length} alerts` : 'alert'}<ArrowRight size={15} /></button>}</div>}
        <section id="departures" className="departure-board" tabIndex={-1}>
          <div className="board-toolbar"><div className="board-title"><h2>Departures</h2><span className="count-badge">{visible.length}</span></div><button className="quick-filter-button direction-control" aria-label="Choose direction" onClick={() => setPanel('direction')}><ArrowUp size={14} /><ArrowDown size={14} />{direction === 'ALL' ? 'All directions' : direction === 'NORTH' ? 'Northbound' : 'Southbound'}<ChevronDown size={13} /></button><div className="board-actions"><button className="text-button" onClick={() => setPanel('alerts')}><TriangleAlert size={14} />Alerts{alerts.length ? ` (${alerts.length})` : ''}</button><button className={'quick-filter-button filter-button ' + (routes.length ? 'active' : '')} onClick={() => setPanel('filters')}><SlidersHorizontal size={15} />Lines{routes.length ? ` (${routes.length})` : ''}<ChevronDown size={13} /></button><button className="icon-button" onClick={refresh} aria-label="Refresh departures"><RefreshCw size={15} /></button></div></div>
          {panel === 'direction' && <Modal title="Choose direction" close={() => setPanel(null)}><div className="direction-options">{[['ALL','All directions'],['NORTH','Northbound'],['SOUTH','Southbound']].map(([id, name]) => <button key={id} aria-pressed={direction === id} onClick={() => { setDirection(id); setPanel(null); }}>{id === 'NORTH' ? <ArrowUp size={18} /> : id === 'SOUTH' ? <ArrowDown size={18} /> : <Layers3 size={18} />}{name}{direction === id && <Check size={18} />}</button>)}</div></Modal>}
          {!board && <div className="loading-board"><span className="loading-line" /><span className="loading-line" /><span className="loading-line" /><p>{error || 'Connecting to your station…'}</p>{error && <button onClick={() => setPanel('stations')} className="text-button">Choose a station</button>}</div>}
          {board && !visible.length && <div className="empty-board"><TrainFront size={30} /><h3>{routes.length || direction !== 'ALL' ? 'No trains match these filters' : 'No departures reported yet'}</h3><p>{routes.length || direction !== 'ALL' ? 'Try all directions and lines.' : 'Feeds refresh automatically. An empty board does not mean service is suspended.'}</p>{(routes.length > 0 || direction !== 'ALL') && <button className="primary-button" onClick={() => { setRoutes([]); setDirection('ALL'); }}>Reset filters</button>}</div>}
          <div className="platform-groups">{sortedGroups.map(group => <PlatformGroup key={group[0].direction + group[0].partId + (group[0].actualTrack || group[0].scheduledTrack || '?')} departures={group} board={board!} now={now} cached={cached} open={setTripKey} />)}</div>
        </section>
        <section className="board-footer"><div><Radio size={14} /><span>FEED CHECK</span></div><div className="source-chips">{trainSources.map(s => <span key={s.id} title={s.error || `Source: ${s.id}`} className={freshness(s.timestamp, now) === 'live' && !s.error ? '' : 'source-stale'}><i />{s.id.replace('gtfs-', '').replace('gtfs', '1–7 / S').toUpperCase()} <b>{ageLabel(s.timestamp, now)}</b></span>)}</div><p>Times are predictions, not promises. Track labels are feed-reported.</p></section>
        <div className="end-note"><span>YOU KNOW THE MAP. WE’LL WATCH THE TRAINS.</span><span>NYC / 24:7</span></div>
      </div>
    </main>
    {panel === 'stations' && <Modal fullscreen title={nearby ? 'Stations near you' : 'Find your station'} eyebrow="THE WHOLE SYSTEM" close={() => setPanel(null)}><div className="station-search-input"><Search size={18} /><input autoFocus autoComplete="off" autoCorrect="off" spellCheck={false} placeholder="Station, line, or borough…" value={query} onChange={e => setQuery(e.target.value)} aria-label="Search stations" />{query && <button className="icon-button" onClick={() => setQuery('')} aria-label="Clear search"><X size={16} /></button>}</div><div className="search-tools"><button className="text-button" onClick={getNearby} disabled={locating}><Crosshair size={16} />{locating ? 'Finding your location…' : 'Use my location'}</button>{nearby && <button className="text-button" onClick={() => setNearby(undefined)}>Clear nearby sort</button>}</div>{locationState && <p className="notice">{locationState}</p>}{catalogError && <p className="notice">{catalogError}</p>}<p className="fine-print">{nearby ? 'Sorted by straight-line distance to the closest station in each complex.' : `${stations.length} station complexes · favorites first`}</p><div className="station-results">{matchingStations.map(({ station: s, distance }) => <div className="station-result" key={s.id}><button onClick={() => selectStation(s.id)}><div><strong>{s.name}</strong><small>{boroughs[s.borough] || s.borough}{distance != null ? ` · ${distance < 1000 ? Math.round(distance) + ' m' : (distance / 1000).toFixed(1) + ' km'} away` : ''}</small></div><div className="route-list">{s.routes.map(r => <Bullet route={r} small key={r} />)}</div></button><button className="icon-button" onClick={() => toggleFavorite(s.id)} aria-label={favorites.includes(s.id) ? `Unfavorite ${s.name}` : `Favorite ${s.name}`}><Star size={16} fill={favorites.includes(s.id) ? 'currentColor' : 'none'} /></button></div>)}</div>{!matchingStations.length && <p className="empty">No stations found. Try another name or line.</p>}</Modal>}
    {panel === 'themes' && <Modal title="Make it yours" eyebrow="SAME SIGNAL. DIFFERENT FREQUENCY." close={() => setPanel(null)}><p className="muted">A subway original, with a few friends from the ferry.</p><div className="theme-grid">{themes.map(t => <button key={t.id} className={'theme-option ' + (theme === t.id ? 'chosen' : '')} onClick={() => setTheme(t.id)} aria-pressed={theme === t.id}><span className="theme-swatch" style={{ background: t.color }} /><span><strong>{t.name}</strong><small>{t.note}</small></span>{theme === t.id && <Check size={17} />}</button>)}</div></Modal>}
    {panel === 'filters' && <Modal title="Your lines" eyebrow="FOCUS THE BOARD" close={() => setPanel(null)}><p className="muted">No selection shows every line. Your filter stays saved between visits.</p><div className="route-filters">{availableRoutes.map(r => <button className={routes.includes(r) ? 'selected' : ''} key={r} aria-pressed={routes.includes(r)} onClick={() => setRoutes(v => v.includes(r) ? v.filter(x => x !== r) : [...v, r])}><Bullet route={r} />{routes.includes(r) && <Check size={15} />}</button>)}</div><button className="text-button" onClick={() => setRoutes([])}>Show every line</button><button className="primary-button full-width" onClick={() => setPanel(null)}>Back to the board</button></Modal>}
    {panel === 'alerts' && <Modal title="Service notes" eyebrow="WHAT CHANGED" close={() => setPanel(null)}><p className="fine-print">Alert feed updated {ageLabel(alertSource?.timestamp, now)}{alertSource?.error ? ' · connection unavailable' : ''}</p>{(cached || freshness(alertSource?.timestamp, now) !== 'live') && <p className="notice">Alert information is stale or unavailable. This is not confirmation of normal service.</p>}{!alerts.length && <p className="empty">No active alerts matched this station in the last feed.</p>}{alerts.map(a => <article className="alert-detail" key={a.id}><div className="route-list">{a.routes.map(r => <Bullet key={r} route={r} small />)}</div><h3>{a.title}</h3><p>{a.description.replace(/<[^>]*>/g, '')}</p><details className="raw-details"><summary>Alert source details</summary><pre>{JSON.stringify(a.raw, null, 2)}</pre></details></article>)}</Modal>}
    <Suspense fallback={<div className="panel-loading" role="status">Opening details…</div>}>{panel === 'fleet' && <Fleet close={() => setPanel(null)} now={now} initialId={fleetId} station={selectStation} trip={key => { setPanel(null); setTripKey(key); }} />}{tripKey && <TrainDetail tripKey={tripKey} close={() => setTripKey(null)} now={now} openFleet={openFleet} />}{panel === 'context' && board && <ContextDetail board={board} close={() => setPanel(null)} now={now} />}</Suspense>
  </div>;
}
function StationShortcut({ station, selected, onClick }: { station: Station; selected: boolean; onClick: () => void }) {
  return <button className={'station-shortcut ' + (selected ? 'current' : '')} onClick={onClick}><span>{station.name}</span><div className="route-list">{station.routes.slice(0, 8).map(r => <Bullet key={r} route={r} small />)}</div>{selected && <span className="current-indicator" />}</button>;
}
function PlatformGroup({ departures, board, now, cached, open }: { departures: Departure[]; board: Board; now: number; cached: boolean; open: (key: string) => void }) {
  const [expanded, setExpanded] = useState(false);
  const first = departures[0], part = board.station.parts.find(p => p.id === first.partId)!;
  const track = first.actualTrack || first.scheduledTrack;
  const direction = first.direction === 'NORTH' ? part.north : first.direction === 'SOUTH' ? part.south : 'Direction unknown';
  const rows = expanded ? departures : departures.slice(0, 5);
  return <section className="platform-card"><header className="platform-heading"><div className="platform-direction">{first.direction === 'NORTH' ? <ArrowUp size={17} /> : <ArrowDown size={17} />}<h3>{direction}</h3></div><span className="platform-track">{track ? `TRACK ${track}` : 'TRACK UNKNOWN'}<span>{first.actualTrack ? 'reported' : track ? 'scheduled' : 'direction group'}</span></span><div className="platform-subheading"><span>{part.line}</span><span>{first.direction === 'NORTH' ? 'NORTHBOUND' : first.direction === 'SOUTH' ? 'SOUTHBOUND' : 'UNKNOWN DIRECTION'}</span></div></header>
    <div className="column-labels"><span>TRAIN / DESTINATION</span><span>CURRENT POSITION</span><span>ARRIVES IN</span></div>
    <div>{rows.map((d, index) => {
      const time = countdown(d.time, d.timestamp, now, cached);
      const positionOld = d.locationTimestamp != null && now - d.locationTimestamp > 90;
      const disabled = !boardable(d), previous = departures.slice(0, index).reverse().find(x => boardable(x));
      const gap = previous?.time != null && d.time != null && !cached && freshness(d.timestamp, now) === 'live' && freshness(previous.timestamp, now) === 'live' ? Math.round((d.time - previous.time) / 60) : null;
      return <button className={'train-row ' + (disabled ? 'canceled ' : '')} key={d.key} onClick={() => open(d.tripKey)} aria-describedby={d.changes?.length ? `changes-${encodeURIComponent(d.key)}` : undefined} aria-label={`${d.route} to ${d.destination}, ${disabled ? d.relationship : time.value + ' ' + time.unit}, ${d.location}. Open train details`}>
        <div className="train-identity"><Bullet route={d.route} /><div className="train-destination"><strong>{d.destination}</strong><span className="train-pattern">{d.pattern}<span className="pattern-marker" title={d.patternSource === 'inferred' ? 'Inferred from remaining stopping pattern' : 'Station corridor metadata'}>{d.patternSource === 'inferred' ? 'est.' : ''}</span></span>{!cached && currentConsist(d.consist, now) && <span className="train-consist" title={`Helium · reported ${ageLabel(d.consist.updatedAt, now)}`}>{[...new Set(d.consist.cars.map(car => car.type).filter(Boolean))].join(' / ') || 'Car type not reported'}{freshness(d.consist.updatedAt, now) !== 'live' ? ' · last reported' : ''}</span>}<div className="train-tags">{disabled && !d.changes?.some(c => c.kind === 'cancellation' || c.kind === 'skip') && <span className="disruption-tag">{d.relationship?.toLowerCase()}</span>}{d.alerts.length > 0 && <span className="disruption-tag">{d.alerts[0]}</span>}{d.assigned === false && <span className="disruption-tag">not yet assigned</span>}{!d.changes && d.actualTrack && d.scheduledTrack && d.actualTrack !== d.scheduledTrack && <span className="disruption-tag">track {d.actualTrack} · scheduled {d.scheduledTrack}</span>}</div><ChangeLabels id={`changes-${encodeURIComponent(d.key)}`} changes={d.changes} now={now} cached={cached} /></div></div>
        <div className={'train-location ' + (positionOld ? 'position-old' : '')}><span><span className="location-dot" />{cached || positionOld || freshness(d.timestamp, now) !== 'live' ? 'Last report: ' : ''}{d.location}</span><small>{d.stopsAway != null && d.stopsAway >= 0 ? `${d.stopsAway} ${d.stopsAway === 1 ? 'stop' : 'stops'} away` : 'Stop-relative position'}{d.locationTimestamp ? ` · ${ageLabel(d.locationTimestamp, now)}` : ''}</small></div>
        <div className="train-time"><div><strong>{disabled ? '—' : time.value}</strong><span>{disabled ? 'not boarding' : time.unit}</span></div><small>{gap != null && gap > 0 ? `+${gap}m after previous` : clockTime(d.time)}</small></div><ChevronRight className="row-chevron" size={15} />
      </button>;
    })}</div>
    {departures.length > 5 && <button className="more-trains" onClick={() => setExpanded(v => !v)}>{expanded ? 'Show fewer trains' : `Show ${departures.length - 5} more trains`}<ChevronDown size={14} /></button>}
  </section>;
}
