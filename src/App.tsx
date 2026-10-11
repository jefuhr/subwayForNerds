import { NJT_LINES, NJT_DEPARTURES_URL, NJT_SCHEDULES_URL, NJT_ALERTS_URL } from '../shared/njt';
import { PATH_ROUTES } from '../shared/path';
import { lazy, Suspense, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { ArrowDown, MoveVertical, ArrowRight, ArrowUp, ArrowUpRight, ArrowLeftRight, Check, ChevronLeft, ChevronDown, ChevronRight, Clock3, Crosshair, ExternalLink, Info, MapPin, Palette, Radio, RefreshCw, Search, Star, TrainFront, TriangleAlert, X } from 'lucide-react';
import type { Board, Station } from '../shared/types';
import { ageLabel, boardable, clockTime, countdown, distanceMeters, distanceLabel, freshness } from '../shared/display';
import { api, locate, storage } from './platform';
import { useBoard, boardSnapshot } from './useBoard';
import StationPager from './StationPager';
import { orderFavorites, stationPages, type Coordinates } from './stationPages';
import type { StationSettings as Preference } from '../shared/settings';
import { getDeviceSettings, subscribeSettings, updateSettings, saveLastStation } from './settings-store';
import { accounts } from './accounts';
import SettingsPanel from './SettingsPanel';
import { track, stationView } from './analytics';
import { themes } from './themes';
import { consistSummary, currentConsist } from '../shared/consist';
import Modal from './Modal';
import DepartureViewMenu from './DepartureViewMenu';
import { groupDepartures, directionLabel, type DepartureGroup, type DepartureView } from '../shared/departureGroups';
import { ChangeLabels } from './Changes';
import { favoriteTrainMatch } from '../shared/favorites';
import { selectStationAutomatically, usableStationLocation } from '../shared/station-selection';
import { carLabel, useTrainFavorites } from './Favorites';
import { useUnits } from './Units';

const TrainDetail = lazy(() => import('./Details').then(m => ({ default: m.TrainDetail })));
const Fleet = lazy(() => import('./Fleet'));
const ContextDetail = lazy(() => import('./Details').then(m => ({ default: m.ContextDetail })));
const boroughs: Record<string, string> = { NJ: 'New Jersey', M: 'Manhattan', B: 'Brooklyn', Bk: 'Brooklyn', Bx: 'Bronx', Q: 'Queens', SI: 'Staten Island' };
const quickStations = ['602', '617', '611', '607'];
const displayRoute = (route: string) => ({ GS: 'S', FS: 'S', H: 'S', SI: 'SIR' })[route] || route;
const routeColor = (route: string) => /^[123]$/.test(route) ? 'red' : /^[456]/.test(route) ? 'green' : /^7/.test(route) ? 'purple' : /^[ACE]$/.test(route) ? 'blue' : /^(B|D|F|FX|M)$/.test(route) ? 'orange' : /^[NQRW]$/.test(route) ? 'yellow' : route === 'G' ? 'lime' : /^[JZ]$/.test(route) ? 'brown' : 'gray';
export function Bullet({ route, small = false }: { route: string; small?: boolean }) {
  if (NJT_LINES[route]) return <span className={`route-bullet njt-route ${small ? 'small' : ''}`} style={{ background: NJT_LINES[route].color }} title={'NJ Transit ' + NJT_LINES[route].name}>{NJT_LINES[route].label}</span>;
  if (route.startsWith('PATH')) return <span className={`route-bullet path-route ${small ? 'small' : ''}`} style={{ background: PATH_ROUTES[route]?.color }} title={'PATH ' + (PATH_ROUTES[route]?.label || '')}>{PATH_ROUTES[route]?.label || 'PATH'}</span>;
  return <span className={`route-bullet ${routeColor(route)} ${small ? 'small' : ''}`} title={route}>{displayRoute(route)}</span>;
}
function readStation() {
  return new URLSearchParams(location.search).get('station') || getDeviceSettings().lastStation;
}
export default function App() {
  const [stationId, setStationId] = useState(readStation);
  const [stations, setStations] = useState<Station[]>(() => storage.get('stations', []));
  const [catalogError, setCatalogError] = useState('');
  const deviceSettings = useSyncExternalStore(subscribeSettings, getDeviceSettings);
  const { favorites, theme, stations: preferences, stationSelection, units } = deviceSettings.settings;
  const navigationGeneration = useRef(0);
  const stationsRef = useRef(stations); stationsRef.current = stations;
  const setFavorites = (update: (value: string[]) => string[]) => updateSettings(s => ({ ...s, favorites: update(s.favorites) }));
  const setTheme = (theme: string) => updateSettings(s => ({ ...s, theme }));
  useEffect(() => accounts.start(), []);
  const previousStation = useRef(deviceSettings.lastStation);
  useEffect(() => {
    if (previousStation.current === deviceSettings.lastStation) return;
    navigationGeneration.current++; previousStation.current = deviceSettings.lastStation; setStationId(deviceSettings.lastStation);
    const url = new URL(location.href); url.searchParams.set('station', deviceSettings.lastStation); history.replaceState({ ...history.state, stationId: deviceSettings.lastStation }, '', url);
  }, [deviceSettings.lastStation]);
  const [panel, setPanel] = useState<'stations' | 'themes' | 'alerts' | 'context' | 'fleet' | 'settings' | null>(() => new URLSearchParams(location.search).has('account') ? 'settings' : null);
  const [tripKey, setTripKey] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [nearby, setNearby] = useState<{ latitude: number; longitude: number }>();
  const [locationState, setLocationState] = useState('');
  const [locating, setLocating] = useState(false);
  const { direction, routes, view } = preferences[stationId] || { direction: 'ALL', routes: [], view: 'track' };
  const savePreference = (patch: Partial<Preference>) => updateSettings(s => ({ ...s, stations: { ...s.stations, [stationId]: { ...(s.stations[stationId] || { direction, routes, view }), ...patch } } }));
  const setDirection = (value: string) => { track('direction', stationId); savePreference({ direction: value }); };
  const setRoutes: React.Dispatch<React.SetStateAction<string[]>> = value => { track('line', stationId); savePreference({ routes: typeof value === 'function' ? value(routes) : value }); };
  const openTrip = (key: string) => { track('train_open', stationId); setTripKey(key); };
  const [fleetId, setFleetId] = useState<string>();
  const openFleet = (id?: string) => { track('fleet_open', stationId); setTripKey(null); setFleetId(id); setPanel('fleet'); };
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  const locationRequested = useRef(false);
  const browsing = useRef(false);
  const [visitLocation, setVisitLocation] = useState<Coordinates>();
  const [temporaryStation, setTemporaryStation] = useState<string | null>(() => favorites.includes(stationId) ? null : stationId);
  const favoriteStations = useMemo(() => orderFavorites(favorites, stations, visitLocation), [favorites, stations, visitLocation]);
  const pages = stationPages(favoriteStations.map(s => s.id), temporaryStation, stationId);
  const { board, cached, error, refresh } = useBoard(stationId, favorites);
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
  useEffect(() => {
    // Preserve the original selection when Back returns to a URL without a station.
    history.replaceState({ ...history.state, stationId }, '', location.href);
  }, []);
  useEffect(() => { const pop = () => {
    navigationGeneration.current++; browsing.current = true;
    const id = new URLSearchParams(location.search).get('station') || history.state?.stationId || readStation(); setStationId(id); saveLastStation(id);
    if (!favorites.includes(id)) setTemporaryStation(id);
    setTripKey(null); setPanel(null); window.scrollTo({ top: 0, behavior: 'instant' });
  }; window.addEventListener('popstate', pop); return () => window.removeEventListener('popstate', pop); }, [favorites]);
  useEffect(() => { const selected = themes.some(t => t.id === theme) ? theme : 'subway'; document.documentElement.dataset.theme = selected; }, [theme]);
  useEffect(() => { if (board) stationView(stationId); }, [board, stationId]);
  useEffect(() => { document.title = station ? `${station.name} · Subways for Nerds` : 'Subways for Nerds'; }, [station?.name]);
  const selectStation = (id: string) => {
    navigationGeneration.current++; browsing.current = true;
    if (!favorites.includes(id)) setTemporaryStation(id);
    setStationId(id); saveLastStation(id); setTripKey(null); setPanel(null);
    const url = new URL(location.href); url.searchParams.set('station', id); history.pushState({ stationId: id }, '', url);
    window.scrollTo({ top: 0, behavior: 'instant' });
  };
  useEffect(() => {
    // One startup location fix orders favorite pages and, unless a link or navigation
    // already chose a station, applies the automatic station selection setting.
    if (locationRequested.current || !stations.length) return;
    locationRequested.current = true;
    const select = !new URLSearchParams(location.search).has('station') && !(stationSelection.mode === 'favorite' && !favoriteStations.length);
    if (!select && favoriteStations.length < 2) return;
    const generation = navigationGeneration.current;
    void locate().then(({ coords, timestamp }) => {
      const position = { latitude: coords.latitude, longitude: coords.longitude, timestamp: timestamp / 1000 };
      if (!usableStationLocation(position, Date.now() / 1000)) return;
      // Do not reorder pages under someone who is already using them.
      if (!browsing.current) setVisitLocation({ latitude: coords.latitude, longitude: coords.longitude });
      const current = getDeviceSettings().settings;
      if (!select || generation !== navigationGeneration.current || JSON.stringify(current.stationSelection) !== JSON.stringify(stationSelection)) return;
      const closest = selectStationAutomatically(stationsRef.current, current.favorites, stationSelection, position, stationId);
      if (!closest || closest.id === stationId) return;
      setStationId(closest.id); setTemporaryStation(current.favorites.includes(closest.id) ? null : closest.id);
      saveLastStation(closest.id);
      setTripKey(null);
      const url = new URL(location.href); url.searchParams.set('station', closest.id); history.replaceState({ stationId: closest.id }, '', url);
    }).catch(() => { /* location is optional; keep the saved station and order */ });
  }, [favorites, stations, stationId, stationSelection, favoriteStations.length]);
  const toggleFavorite = (id: string) => {
    browsing.current = true;
    track(favorites.includes(id) ? 'favorite_remove' : 'favorite_add', id);
    if (favorites.includes(id) && id === stationId) setTemporaryStation(id);
    if (!favorites.includes(id) && temporaryStation === id) setTemporaryStation(null);
    setFavorites(v => v.includes(id) ? v.filter(s => s !== id) : [...v, id]);
  };
  const getNearby = async () => {
    setPanel('stations'); setQuery(''); setLocationState(''); setLocating(true);
    try { const fix = await locate(); setNearby(fix.coords); }
    catch (e) { setLocationState((e as GeolocationPositionError).code === 1 ? 'Location permission is off. You can still search for any station.' : 'Could not get your location. Search for a station or try again.'); }
    finally { setLocating(false); }
  };
  const matchingStations = useMemo(() => {
    const terms = query.toLowerCase().replace(/[–—-]/g, ' ').trim().split(/\s+/).filter(Boolean);
    return stations.filter(s => terms.every(t => `${s.name} ${NJT_LINES[s.routes[0]] ? 'NJT light rail lightrail' : ''} ${s.municipality || ''} ${s.parts.map(p => p.stationId).join(' ')} ${boroughs[s.borough] || s.borough} ${s.routes.join(' ')} ${s.parts.map(p => p.line).join(' ')}`.toLowerCase().replace(/[–—-]/g, ' ').includes(t)))
      .map(s => ({ station: s, distance: nearby ? Math.min(...s.parts.map(p => distanceMeters(nearby.latitude, nearby.longitude, p.lat, p.lon))) : null }))
      .sort((a, b) => nearby ? (a.distance || 0) - (b.distance || 0) : Number(favorites.includes(b.station.id)) - Number(favorites.includes(a.station.id)) || a.station.name.localeCompare(b.station.name));
  }, [stations, query, nearby, favorites]);
  const alertSource = board?.sources.find(s => s.id === 'subway-alerts');
  const alerts = board?.alerts || [];
  const shortcuts = quickStations.map(id => stations.find(s => s.id === id)).filter((s): s is Station => !!s);
  return <div className="app-shell" onPointerDownCapture={() => { browsing.current = true; }} onTouchStartCapture={() => { browsing.current = true; }} onKeyDownCapture={() => { browsing.current = true; }}>
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
      <header className="topbar"><div className="mobile-brand"><img src={import.meta.env.BASE_URL + 'kitty.png'} alt="" width={128} height={128} />subways for nerds<span>.</span></div><div className="desktop-breadcrumb"><span>THE SYSTEM</span><ChevronRight size={12} /><span>STATION BOARD</span></div><div className="topbar-right"><button className="text-button" onClick={() => setPanel('settings')} aria-label="Open settings">Settings</button><button className="text-button mobile-only" onClick={() => openFleet()} aria-label="Open fleet"><TrainFront size={16} />Fleet</button><span className="system-clock"><Clock3 size={13} />{clockTime(now, units.time)}<span> NYC</span></span><button className="icon-button mobile-only" onClick={() => setPanel('themes')} aria-label="Choose theme"><Palette size={18} /></button><a className="ferry-link" href="https://juliet.nyc/ferryTimesMobile/" target="_blank" rel="noreferrer">Taking the ferry? <ArrowUpRight size={13} /></a></div></header>
      <StationPager pages={pages} current={stationId} disabled={!!panel || !!tripKey} select={selectStation} name={id => stations.find(s => s.id === id)?.name || `Station ${id}`} render={(id, active) => {
        const snapshot = id === stationId ? { board, cached, error } : boardSnapshot(id);
        return <StationPage key={id} {...snapshot} stationId={id} station={snapshot.board?.station || stations.find(s => s.id === id)}
          active={active} now={now} favorites={favorites} preference={preferences[id] || { direction: 'ALL', routes: [], view: 'track' }}
          savePreference={savePreference} setDirection={setDirection} setRoutes={setRoutes} toggleFavorite={toggleFavorite}
          setPanel={setPanel} setNearby={setNearby} getNearby={getNearby} openTrip={openTrip} refresh={refresh} />;
      }} />
    </main>
    {panel === 'stations' && <Modal fullscreen title={nearby ? 'Stations near you' : 'Find your station'} eyebrow="THE WHOLE SYSTEM" close={() => setPanel(null)}><div className="station-search-input"><Search size={18} /><input autoFocus autoComplete="off" autoCorrect="off" spellCheck={false} placeholder="Station, line, or borough…" value={query} onChange={e => setQuery(e.target.value)} aria-label="Search stations" />{query && <button className="icon-button" onClick={() => setQuery('')} aria-label="Clear search"><X size={16} /></button>}</div><div className="search-tools"><button className="text-button" onClick={getNearby} disabled={locating}><Crosshair size={16} />{locating ? 'Finding your location…' : 'Use my location'}</button>{nearby && <button className="text-button" onClick={() => setNearby(undefined)}>Clear nearby sort</button>}</div>{locationState && <p className="notice">{locationState}</p>}{catalogError && <p className="notice">{catalogError}</p>}<p className="fine-print">{nearby ? 'Sorted by straight-line distance to the closest station in each complex.' : `${stations.length} station complexes · favorites first`}</p><div className="station-results">{matchingStations.map(({ station: s, distance }) => <div className="station-result" key={s.id}><button onClick={() => selectStation(s.id)}><div><strong>{s.name}</strong><small>{boroughs[s.borough] || s.borough}{distance != null ? ` · ${distanceLabel(distance, units.distance)} away` : ''}</small></div><div className="route-list">{s.routes.map(r => <Bullet route={r} small key={r} />)}</div></button><button className="icon-button" onClick={() => toggleFavorite(s.id)} aria-label={favorites.includes(s.id) ? `Unfavorite ${s.name}` : `Favorite ${s.name}`}><Star size={16} fill={favorites.includes(s.id) ? 'currentColor' : 'none'} /></button></div>)}</div>{!matchingStations.length && <p className="empty">No stations found. Try another name or line.</p>}</Modal>}
    {deviceSettings.error && <p role="alert" className="notice">{deviceSettings.error}</p>}
    {panel === 'settings' && <Modal title="Settings" eyebrow="MAKE IT YOURS" close={() => setPanel(null)}><SettingsPanel stationNames={Object.fromEntries(stations.map(s => [s.id, s.name]))} onTheme={() => setPanel('themes')} onFleet={openFleet} /></Modal>}
    {panel === 'themes' && <Modal title="Make it yours" eyebrow="SAME SIGNAL. DIFFERENT FREQUENCY." close={() => setPanel(null)}><p className="muted">A subway original, with a few friends from the ferry.</p><div className="theme-grid">{themes.map(t => <button key={t.id} className={'theme-option ' + (theme === t.id ? 'chosen' : '')} onClick={() => setTheme(t.id)} aria-pressed={theme === t.id}><span className="theme-swatch" style={{ background: t.color }} /><span><strong>{t.name}</strong></span>{theme === t.id && <Check size={17} />}</button>)}</div></Modal>}
    {panel === 'alerts' && <Modal title="Service notes" eyebrow="WHAT CHANGED" close={() => setPanel(null)}><p className="fine-print">Alert feed updated {ageLabel(alertSource?.timestamp, now)}{alertSource?.error ? ' · connection unavailable' : ''}</p>{(cached || freshness(alertSource?.timestamp, now) !== 'live') && <p className="notice">Alert information is stale or unavailable. This is not confirmation of normal service.</p>}{!alerts.length && <p className="empty">No active alerts matched this station in the last feed.</p>}{alerts.map(a => <article className="alert-detail" key={a.id}><div className="route-list">{a.routes.map(r => <Bullet key={r} route={r} small />)}</div><h3>{a.title}</h3><p>{a.description.replace(/<[^>]*>/g, '')}</p><details className="raw-details"><summary>Alert source details</summary><pre>{JSON.stringify(a.raw, null, 2)}</pre></details></article>)}</Modal>}
    <Suspense fallback={<div className="panel-loading" role="status">Opening details…</div>}>{panel === 'fleet' && <Fleet close={() => setPanel(null)} now={now} initialId={fleetId} station={selectStation} trip={key => { setPanel(null); openTrip(key); }} />}{tripKey && <TrainDetail tripKey={tripKey} close={() => setTripKey(null)} now={now} openFleet={openFleet} />}{panel === 'context' && board && <ContextDetail board={board} close={() => setPanel(null)} now={now} />}</Suspense>
  </div>;
}
function StationPage({ stationId, station, board, cached, error, active, now, favorites, preference, savePreference, setDirection, setRoutes, toggleFavorite, setPanel, setNearby, getNearby, openTrip, refresh }: {
  stationId: string; station?: Station; board?: Board; cached: boolean; error: string; active: boolean; now: number;
  favorites: string[]; preference: Preference; savePreference: (patch: Partial<Preference>) => void;
  setDirection: (value: string) => void; setRoutes: React.Dispatch<React.SetStateAction<string[]>>;
  toggleFavorite: (id: string) => void; setPanel: (panel: 'stations' | 'themes' | 'alerts' | 'context' | 'fleet' | 'settings' | null) => void;
  setNearby: (coords: Coordinates | undefined) => void; getNearby: () => void; openTrip: (key: string) => void; refresh: () => void;
}) {
  const externalDepartures = station?.departureMode === 'external';
  const { direction, routes, view } = preference;
  const availableRoutes = [...new Set([...(station?.routes || []), ...(board?.departures.map(d => d.route) || [])].map(displayRoute))];
  const visible = (board?.departures || []).filter(d => (direction === 'ALL' || d.direction === direction) && (!routes.length || routes.includes(displayRoute(d.route))) && !(freshness(d.timestamp, now) === 'live' && d.time != null && d.time < now - 30));
  const sortedGroups = board ? groupDepartures(visible, board.station, view) : [];
  const services = [...new Set(sortedGroups.map(g => g.service).filter((s): s is string => !!s))];
  const trainSources = board?.sources.filter(s => s.id !== 'subway-alerts' && s.id !== 'helium') || [];
  const live = !cached && trainSources.some(s => freshness(s.timestamp, now) === 'live');
  const degraded = trainSources.some(s => freshness(s.timestamp, now) !== 'live' || s.error);
  const alerts = board?.alerts || [];
  return (
      <div className="board-content">
        <section className="station-heading"><div className="station-kicker"><span className="eyebrow">{boroughs[station?.borough || ''] || 'NEW YORK CITY'} / STATION {stationId}</span><span className={'status-pill ' + (live ? 'live' : 'stale')}><i />{externalDepartures ? 'STATION DIRECTORY' : live ? degraded ? 'PARTIAL LIVE DATA' : 'LIVE FEED' : cached && board ? 'CACHED BOARD' : board ? 'AWAITING LIVE DATA' : 'CONNECTING'}</span></div>
          <div className="station-title-row"><button className="station-name-button" onClick={() => { setPanel('stations'); setNearby(undefined); }}><h1>{station?.name || 'Your next train'}</h1><ChevronDown size={24} /></button><button className={'icon-button favorite-button ' + (favorites.includes(stationId) ? 'active' : '')} onClick={() => toggleFavorite(stationId)} aria-label={favorites.includes(stationId) ? 'Remove favorite station' : 'Favorite this station'} aria-pressed={favorites.includes(stationId)}><Star size={22} fill={favorites.includes(stationId) ? 'currentColor' : 'none'} /></button></div>
          <div className="station-meta"><div className="route-list">{(station?.routes || []).map(r => <Bullet route={r} small key={r} />)}</div><span className="station-description">{station?.parts.length ? `${station.parts.length} ${station.parts.length === 1 ? 'station' : 'connected stations'}` : 'Station-first. Always.'}</span><button className="text-button" onClick={() => board && setPanel('context')} disabled={!board}><Info size={14} />Station info<ArrowUpRight size={13} /></button><button className="nearby-mobile text-button" onClick={getNearby}><Crosshair size={16} />Nearby</button></div>
        </section>
        {(error || degraded) && <div className="notice-bar"><TriangleAlert size={16} /><span>{error || 'Some feeds are stale or unavailable. Check source ages below.'}</span>{alerts.length > 0 && <button onClick={() => setPanel('alerts')}>View {alerts.length > 1 ? `${alerts.length} alerts` : 'alert'}<ArrowRight size={15} /></button>}</div>}
        <section id={active ? 'departures' : undefined} className="departure-board" tabIndex={-1}>
          {externalDepartures ? <NjtStationInfo station={station!} /> : <>
          <div className="board-toolbar"><div className="board-title"><h2>Departures</h2><span className="count-badge">{visible.length}</span><DepartureViewMenu key={stationId} value={view} onChange={value => savePreference({ view: value })} /></div><div className="board-actions"><button className="text-button" onClick={() => setPanel('alerts')}><TriangleAlert size={14} />Alerts{alerts.length ? ` (${alerts.length})` : ''}</button><button className="icon-button" onClick={refresh} aria-label="Refresh departures"><RefreshCw size={15} /></button></div></div>
          <div className="departure-filters">
            <div className="direction-filters" role="group" aria-label="Direction filters">{(station?.id.startsWith('path-') ? [['ALL', 'All directions'], ['TO_NY', 'To New York'], ['TO_NJ', 'To New Jersey']] : [['ALL', 'All directions'], ['NORTH', 'Northbound'], ['SOUTH', 'Southbound']]).map(([id, name]) => <button key={id} aria-label={name} title={name} aria-pressed={direction === id} onClick={() => setDirection(id)}>{id === 'ALL' ? <MoveVertical size={19} /> : (id === 'NORTH' || id === 'TO_NY') ? <ArrowUp size={19} /> : <ArrowDown size={19} />}</button>)}</div>
            <RouteFilters availableRoutes={availableRoutes} routes={routes} setRoutes={setRoutes} />
          </div>
          {!board && <div className="loading-board"><span className="loading-line" /><span className="loading-line" /><span className="loading-line" /><p>{error || 'Connecting to your station…'}</p>{error && <button onClick={() => setPanel('stations')} className="text-button">Choose a station</button>}</div>}
          {board && !visible.length && <div className="empty-board"><TrainFront size={30} /><h3>{routes.length || direction !== 'ALL' ? 'No trains match these filters' : 'No departures reported yet'}</h3><p>{routes.length || direction !== 'ALL' ? 'Try all directions and lines.' : 'Feeds refresh automatically. An empty board does not mean service is suspended.'}</p>{(routes.length > 0 || direction !== 'ALL') && <button className="primary-button" onClick={() => { track('reset', stationId); savePreference({ routes: [], direction: 'ALL' }); }}>Reset filters</button>}</div>}
          <div className="platform-groups">{view === 'service' ? services.map(service => <section className="service-section" key={stationId + service} aria-label={`Service ${service}`}><h3 className="service-heading"><Bullet route={service} />Service {service}</h3><div className="service-directions">{sortedGroups.filter(g => g.service === service).map(group => <PlatformGroup key={stationId + group.key} group={group} view={view} board={board!} now={now} cached={cached} open={openTrip} />)}</div></section>) : sortedGroups.map(group => <PlatformGroup key={stationId + group.key} group={group} view={view} board={board!} now={now} cached={cached} open={openTrip} />)}</div>
          </>}
        </section>
        {!externalDepartures && <section className="board-footer"><div><Radio size={14} /><span>FEED CHECK</span></div><div className="source-chips">{trainSources.map(s => <span key={s.id} title={s.error || `Source: ${s.id}`} className={freshness(s.timestamp, now) === 'live' && !s.error ? '' : 'source-stale'}><i />{s.id.replace('gtfs-', '').replace('gtfs', '1–7 / S').toUpperCase()} <b>{ageLabel(s.timestamp, now)}</b></span>)}</div><p>Times are predictions, not promises. Track labels are feed-reported.</p></section>}
        <div className="end-note"><span>YOU KNOW THE MAP. WE’LL WATCH THE TRAINS.</span><a href={import.meta.env.BASE_URL + 'stats'}>Stats</a><span>NYC / 24:7</span></div>
        <p className="fine-print">First-party usage statistics estimate visits and returning browsers using a random browser ID. Station views and control actions are retained for one year. No location or search text is collected.</p>
      </div>
  );
}

function NjtStationInfo({ station }: { station: Station }) {
  return <div className="njt-station-info">
    <h2>{NJT_LINES[station.routes[0]]?.name}</h2>
    <p>{station.municipality} · NJ Transit station {station.parts[0].stationId}</p>
    <p>Live light rail departures are not connected in this app. Check NJ Transit for upcoming trains, schedules and service changes.</p>
    <div className="njt-links">
      <a className="primary-button" href={NJT_DEPARTURES_URL} target="_blank" rel="noreferrer">NJ Transit departures <ArrowUpRight size={15} /></a>
      <a className="text-button" href={NJT_SCHEDULES_URL} target="_blank" rel="noreferrer">Light rail schedules <ArrowUpRight size={15} /></a>
      <a className="text-button" href={NJT_ALERTS_URL} target="_blank" rel="noreferrer">Service alerts <ArrowUpRight size={15} /></a>
    </div>
  </div>;
}

function RouteFilters({ availableRoutes, routes, setRoutes }: { availableRoutes: string[]; routes: string[]; setRoutes: React.Dispatch<React.SetStateAction<string[]>> }) {
  const ref = useRef<HTMLDivElement>(null);
  const [overflow, setOverflow] = useState(false);
  const [atEnd, setAtEnd] = useState(false);
  useLayoutEffect(() => {
    const el = ref.current!;
    const update = () => {
      setOverflow(el.scrollWidth > el.clientWidth + 1);
      setAtEnd(el.scrollLeft + el.clientWidth >= el.scrollWidth - 1);
    };
    const observer = new ResizeObserver(update);
    observer.observe(el);
    el.addEventListener('scroll', update);
    update();
    return () => { observer.disconnect(); el.removeEventListener('scroll', update); };
  }, [availableRoutes.join('|')]);
  return <div className="route-filter-strip">
    <div ref={ref} className="route-filters" role="group" aria-label="Line filters"><button aria-pressed={!routes.length} onClick={() => setRoutes([])}>All lines</button>{availableRoutes.map(r => <button key={r} aria-label={`Line ${r}`} aria-pressed={routes.includes(r)} onClick={() => setRoutes(v => v.includes(r) ? v.filter(x => x !== r) : [...v, r])}><Bullet route={r} /></button>)}</div>
    {overflow && <button className="route-scroll" aria-label={atEnd ? 'Scroll to first lines' : 'Scroll to more lines'} onClick={() => {
      const el = ref.current!;
      el.scrollTo({ left: atEnd ? 0 : el.scrollLeft + Math.max(44, el.clientWidth - 44), behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
    }}>{atEnd ? <ChevronLeft size={18} /> : <ChevronRight size={18} />}</button>}
  </div>;
}
function StationShortcut({ station, selected, onClick }: { station: Station; selected: boolean; onClick: () => void }) {
  return <button className={'station-shortcut ' + (selected ? 'current' : '')} onClick={onClick}><span>{station.name}</span><div className="route-list">{station.routes.slice(0, 8).map(r => <Bullet key={r} route={r} small />)}</div>{selected && <span className="current-indicator" />}</button>;
}
function PlatformGroup({ group, view, board, now, cached, open }: { group: DepartureGroup; view: DepartureView; board: Board; now: number; cached: boolean; open: (key: string) => void }) {
  const trainFavorites = useTrainFavorites();
  const units = useUnits();
  const [expanded, setExpanded] = useState(false);
  const departures = group.departures;
  const first = departures[0], part = board.station.parts.find(p => p.id === first.partId);
  const track = first.actualTrack || first.scheduledTrack;
  const direction = view === 'track' ? (first.direction === 'NORTH' ? part?.north : first.direction === 'SOUTH' ? part?.south : undefined) || directionLabel(group.direction) : directionLabel(group.direction);
  const rows = expanded ? departures : departures.slice(0, 5);
  return <section className="platform-card"><header className="platform-heading"><div className="platform-direction">{group.direction === 'NORTH' ? <ArrowUp size={17} /> : group.direction === 'SOUTH' ? <ArrowDown size={17} /> : <MoveVertical size={17} />}<h3>{direction}</h3></div>{view === 'track' && <span className="platform-track">{track ? `TRACK ${track}` : 'TRACK UNKNOWN'}<span>{first.actualTrack ? 'reported' : track ? 'scheduled' : 'direction group'}</span></span>}<div className="platform-subheading"><span>{view === 'track' ? part?.line || first.partId : view === 'direction' ? 'All platforms' : view === 'service' ? `Service ${group.service}` : group.label}</span><span>{first.direction === 'NORTH' ? 'NORTHBOUND' : first.direction === 'SOUTH' ? 'SOUTHBOUND' : directionLabel(first.direction).toUpperCase()}</span></div></header>
    <div className="column-labels"><span>TRAIN / DESTINATION</span><span>CURRENT POSITION</span><span>ARRIVES IN</span></div>
    <div>{rows.map((d, index) => {
      const time = countdown(d.time, d.timestamp, now, cached, units.time);
      const favorite = favoriteTrainMatch(d.consist, d.feed, trainFavorites, now, cached);
      const favoriteLabel = favorite ? favorite.exactConsist ? 'Favorite consist' : 'Favorite cars: ' + favorite.carIDs.map(carLabel).join(', ') : '';
      const positionOld = d.locationTimestamp != null && now - d.locationTimestamp > 90;
      const disabled = !boardable(d), previous = departures.slice(0, index).reverse().find(x => boardable(x));
      const gap = previous?.time != null && d.time != null && !cached && freshness(d.timestamp, now) === 'live' && freshness(previous.timestamp, now) === 'live' ? Math.round((d.time - previous.time) / 60) : null;
      return <button className={'train-row ' + (disabled ? 'canceled ' : '') + (favorite ? 'favorite-train' : '')} key={d.key} onClick={() => open(d.tripKey)} aria-describedby={d.changes?.length ? `changes-${encodeURIComponent(d.key)}` : undefined} aria-label={`${d.route} to ${d.destination}, ${disabled ? d.relationship : time.value + ' ' + time.unit}, ${d.location}.${view !== 'track' ? ` ${d.area || d.partId}, ${d.actualTrack ? 'reported track' : d.scheduledTrack ? 'scheduled track' : 'track unknown'}.` : ''} ${favoriteLabel ? favoriteLabel + '. ' : ''}Open train details`}>
        <div className="train-identity"><Bullet route={d.route} /><div className="train-destination"><strong>{d.destination}</strong>{favorite && <span className="favorite-train-label"><Star size={12} fill="currentColor" aria-hidden="true" />{favoriteLabel}</span>}<span className="train-pattern">{d.pattern}<span className="pattern-marker" title={d.patternSource === 'inferred' ? 'Inferred from remaining stopping pattern' : 'Station corridor metadata'}>{d.patternSource === 'inferred' ? 'est.' : ''}</span></span>{!cached && currentConsist(d.consist, now) && <span className="train-consist" title={`Helium · reported ${ageLabel(d.consist.updatedAt, now)}`}>{[...new Set(d.consist.cars.map(car => car.type).filter(Boolean))].join(' / ') || 'Car type not reported'} · {consistSummary(d.consist.cars)}{freshness(d.consist.updatedAt, now) !== 'live' ? ' · last reported' : ''}</span>}{view !== 'track' && <span className="train-boarding">{d.area || d.partId} · {d.actualTrack ? 'reported track' : d.scheduledTrack ? 'scheduled track' : 'track unknown'}</span>}<div className="train-tags">{disabled && !d.changes?.some(c => c.kind === 'cancellation' || c.kind === 'skip') && <span className="disruption-tag">{d.relationship?.toLowerCase()}</span>}{d.alerts.length > 0 && <span className="change-label change-unknown" title={d.alerts.join(" · ")} aria-label={d.alerts.join(" · ")}><TriangleAlert size={16} aria-hidden="true" /></span>}{d.assigned === false && <span className="disruption-tag">not yet assigned</span>}{!d.changes && d.actualTrack && d.scheduledTrack && d.actualTrack !== d.scheduledTrack && <span className="disruption-tag">track {d.actualTrack} · scheduled {d.scheduledTrack}</span>}</div><ChangeLabels iconsOnly id={`changes-${encodeURIComponent(d.key)}`} changes={d.changes} now={now} cached={cached} /></div></div>
        <div className={'train-location ' + (positionOld ? 'position-old' : '')}><span><span className="location-dot" />{cached || positionOld || freshness(d.timestamp, now) !== 'live' ? 'Last report: ' : ''}{d.location}</span><small>{d.stopsAway != null && d.stopsAway >= 0 ? `${d.stopsAway} ${d.stopsAway === 1 ? 'stop' : 'stops'} away` : 'Stop-relative position'}{d.locationTimestamp ? ` · ${ageLabel(d.locationTimestamp, now)}` : ''}</small></div>
        <div className="train-time"><div><strong>{disabled ? '—' : time.value}</strong><span>{disabled ? 'not boarding' : time.unit}</span></div><small>{gap != null && gap > 0 ? `+${gap}m after previous` : clockTime(d.time, units.time)}</small></div><ChevronRight className="row-chevron" size={15} />
      </button>;
    })}</div>
    {departures.length > 5 && <button className="more-trains" onClick={() => setExpanded(v => !v)}>{expanded ? 'Show fewer trains' : `Show ${departures.length - 5} more trains`}<ChevronDown size={14} /></button>}
  </section>;
}
