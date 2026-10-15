import { useLayoutEffect, useRef, useState } from 'react';
import { ArrowDown, ArrowUp, ChevronLeft, ChevronRight, MoveVertical } from 'lucide-react';
import { NJT_LINES } from '../shared/njt';
import { PATH_ROUTES } from '../shared/path';
import { routeFilterKey } from '../shared/transfer-filters';

/** Station board filter controls, shared by boards and transfer views. */
export const displayRoute = routeFilterKey;
const routeColor = (route: string) => /^[123]$/.test(route) ? 'red' : /^[456]/.test(route) ? 'green' : /^7/.test(route) ? 'purple' : /^[ACE]$/.test(route) ? 'blue' : /^(B|D|F|FX|M)$/.test(route) ? 'orange' : /^[NQRW]$/.test(route) ? 'yellow' : route === 'G' ? 'lime' : /^[JZ]$/.test(route) ? 'brown' : 'gray';
export function Bullet({ route, small = false }: { route: string; small?: boolean }) {
  if (NJT_LINES[route]) return <span className={`route-bullet njt-route ${small ? 'small' : ''}`} style={{ background: NJT_LINES[route].color }} title={'NJ Transit ' + NJT_LINES[route].name}>{NJT_LINES[route].label}</span>;
  if (route.startsWith('PATH')) return <span className={`route-bullet path-route ${small ? 'small' : ''}`} style={{ background: PATH_ROUTES[route]?.color }} title={'PATH ' + (PATH_ROUTES[route]?.label || '')}>{PATH_ROUTES[route]?.label || 'PATH'}</span>;
  return <span className={`route-bullet ${routeColor(route)} ${small ? 'small' : ''}`} title={route}>{displayRoute(route)}</span>;
}
export function DirectionFilters({ stationId, direction, setDirection, label = 'Direction filters' }: { stationId: string; direction: string; setDirection: (value: string) => void; label?: string }) {
  return <div className="direction-filters" role="group" aria-label={label}>{(stationId.startsWith('path-') ? [['ALL', 'All directions'], ['TO_NY', 'To New York'], ['TO_NJ', 'To New Jersey']] : [['ALL', 'All directions'], ['NORTH', 'Northbound'], ['SOUTH', 'Southbound']]).map(([id, name]) => <button key={id} aria-label={name} title={name} aria-pressed={direction === id} onClick={() => setDirection(id)}>{id === 'ALL' ? <MoveVertical size={19} /> : (id === 'NORTH' || id === 'TO_NY') ? <ArrowUp size={19} /> : <ArrowDown size={19} />}</button>)}</div>;
}
export function RouteFilters({ availableRoutes, routes, setRoutes, label = 'Line filters' }: { availableRoutes: string[]; routes: string[]; setRoutes: React.Dispatch<React.SetStateAction<string[]>>; label?: string }) {
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
    <div ref={ref} className="route-filters" role="group" aria-label={label}><button aria-pressed={!routes.length} onClick={() => setRoutes([])}>All lines</button>{availableRoutes.map(r => <button key={r} aria-label={`Line ${r}`} aria-pressed={routes.includes(r)} onClick={() => setRoutes(v => v.includes(r) ? v.filter(x => x !== r) : [...v, r])}><Bullet route={r} /></button>)}</div>
    {overflow && <button className="route-scroll" aria-label={atEnd ? 'Scroll to first lines' : 'Scroll to more lines'} onClick={() => {
      const el = ref.current!;
      el.scrollTo({ left: atEnd ? 0 : el.scrollLeft + Math.max(44, el.clientWidth - 44), behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
    }}>{atEnd ? <ChevronLeft size={18} /> : <ChevronRight size={18} />}</button>}
  </div>;
}
