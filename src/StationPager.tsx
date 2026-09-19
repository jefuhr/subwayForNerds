import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';

export function PageControls({ pages, current, name, select }: { pages: string[]; current: string; name: (id: string) => string; select: (id: string) => void }) {
  const ref = useRef<HTMLElement>(null);
  const index = pages.indexOf(current);
  useEffect(() => {
    const dot = ref.current?.querySelector<HTMLElement>('[aria-current="true"]');
    if (dot?.parentElement) {
      const strip = dot.parentElement;
      strip.scrollLeft = dot.offsetLeft - strip.offsetLeft - strip.clientWidth / 2 + dot.clientWidth / 2;
    }
  }, [current, pages.join('|')]);
  if (pages.length < 2) return null;
  return <nav ref={ref} className="station-pager" tabIndex={-1} aria-label="Station pages" onKeyDown={e => {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
    e.preventDefault(); const id = pages[index + (e.key === 'ArrowLeft' ? -1 : 1)]; if (id) select(id);
  }}>
    <button className="icon-button" aria-label="Previous station" disabled={index <= 0} onClick={() => select(pages[index - 1])}><ChevronLeft size={18} /></button>
    <div className="station-page-dots">{pages.map((id, i) => <button key={id} aria-label={`Go to ${name(id)}, page ${i + 1} of ${pages.length}`} aria-current={id === current ? 'true' : undefined} title={name(id)} onClick={() => select(id)}><span /></button>)}</div>
    <span className="station-page-count" aria-live="polite">{index + 1} / {pages.length}</span>
    <button className="icon-button" aria-label="Next station" disabled={index >= pages.length - 1} onClick={() => select(pages[index + 1])}><ChevronRight size={18} /></button>
  </nav>;
}

export default function StationPager({ pages, current, disabled, select, render }: {
  pages: string[]; current: string; disabled: boolean; select: (id: string) => void;
  render: (id: string, active: boolean, navigate: (id: string) => void) => ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState(0);
  const [sliding, setSliding] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const gesture = useRef<{ x: number; y: number; axis?: 'x' | 'y' } | null>(null);
  const suppressClick = useRef(false);
  const restorePagerFocus = useRef(false);
  const index = pages.indexOf(current);
  const reset = () => { clearTimeout(timer.current); timer.current = undefined; setDrag(0); setSliding(false); gesture.current = null; };
  useLayoutEffect(() => {
    reset();
    if (restorePagerFocus.current) {
      ref.current?.querySelector<HTMLElement>('.active-page .station-pager')?.focus({ preventScroll: true });
      restorePagerFocus.current = false;
    }
  }, [current, disabled, pages.join('|')]);
  useEffect(() => () => clearTimeout(timer.current), []);
  const navigate = (id: string) => {
    if (!id || id === current || disabled || timer.current) return;
    restorePagerFocus.current = !!document.activeElement?.closest('.station-pager');
    const target = pages.indexOf(id);
    if (Math.abs(target - index) !== 1 || matchMedia('(prefers-reduced-motion: reduce)').matches) { select(id); return; }
    setSliding(true); setDrag((target > index ? -1 : 1) * (ref.current?.clientWidth || 0));
    timer.current = setTimeout(() => { timer.current = undefined; select(id); setDrag(0); setSliding(false); }, 200);
  };
  // Native non-passive touchmove lets vertical scrolling remain native while a
  // horizontal gesture suppresses scrolling and the eventual train-row click.
  useEffect(() => {
    const el = ref.current!;
    const start = (e: TouchEvent) => {
      suppressClick.current = false;
      if (disabled || timer.current || pages.length < 2 || e.touches.length !== 1 || (e.target as Element).closest('.route-filter-strip, .station-pager, .departure-view, input, select, textarea, a')) return;
      gesture.current = { x: e.touches[0].clientX, y: e.touches[0].clientY };
    };
    const move = (e: TouchEvent) => {
      const g = gesture.current;
      if (!g) return;
      if (e.touches.length !== 1) { reset(); return; }
      const dx = e.touches[0].clientX - g.x, dy = e.touches[0].clientY - g.y;
      if (!g.axis && Math.max(Math.abs(dx), Math.abs(dy)) > 10) g.axis = Math.abs(dx) > Math.abs(dy) * 1.2 ? 'x' : 'y';
      if (g.axis !== 'x') return;
      e.preventDefault(); suppressClick.current = true;
      const bounded = (dx > 0 && index === 0) || (dx < 0 && index === pages.length - 1);
      setDrag(bounded ? dx * 0.15 : Math.max(-el.clientWidth, Math.min(el.clientWidth, dx)));
    };
    const end = (e: TouchEvent) => {
      const g = gesture.current; gesture.current = null;
      if (!g || g.axis !== 'x') return;
      const dx = e.changedTouches[0].clientX - g.x;
      const target = pages[index + (dx < 0 ? 1 : -1)];
      if (Math.abs(dx) >= Math.min(70, el.clientWidth * 0.2) && target) navigate(target);
      else { setDrag(0); }
    };
    const cancel = () => reset();
    el.addEventListener('touchstart', start, { passive: true });
    el.addEventListener('touchmove', move, { passive: false });
    el.addEventListener('touchend', end); el.addEventListener('touchcancel', cancel);
    return () => { el.removeEventListener('touchstart', start); el.removeEventListener('touchmove', move); el.removeEventListener('touchend', end); el.removeEventListener('touchcancel', cancel); };
  }, [current, disabled, pages.join('|')]);
  return <div ref={ref} className="station-pages" onClickCapture={e => { if (suppressClick.current) { e.preventDefault(); e.stopPropagation(); suppressClick.current = false; } }}>
    <div className={'station-page-track' + (sliding ? ' sliding' : '') + (drag ? ' moving' : '')} style={{ transform: `translateX(${drag}px)` }}>
      {[-1, 0, 1].map(offset => {
        const id = pages[index + offset];
        return id ? <div key={id} className={'station-page ' + (offset === 0 ? 'active-page' : 'neighbor-page')} style={offset ? { left: `${offset * 100}%` } : undefined} inert={offset !== 0} aria-hidden={offset !== 0 ? true : undefined}>{render(id, offset === 0, navigate)}</div> : null;
      })}
    </div>
  </div>;
}
