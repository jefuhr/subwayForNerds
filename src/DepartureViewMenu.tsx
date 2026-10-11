import { useEffect, useRef, useState } from 'react';
import { Check, ChevronDown } from 'lucide-react';
import { departureViews, type DepartureView } from '../shared/departureGroups';

export default function DepartureViewMenu({ value, onChange }: { value: DepartureView; onChange: (view: DepartureView) => void }) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null), trigger = useRef<HTMLButtonElement>(null);
  const items = useRef<(HTMLButtonElement | null)[]>([]);
  const selected = departureViews.findIndex(v => v.id === value);
  useEffect(() => {
    if (!open) return;
    items.current[selected]?.focus();
    const outside = (event: PointerEvent) => { if (!root.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener('pointerdown', outside);
    return () => document.removeEventListener('pointerdown', outside);
  }, [open, selected]);
  const close = () => { setOpen(false); trigger.current?.focus(); };
  return <div className="departure-view" ref={root} onBlur={e => { if (!e.currentTarget.contains(e.relatedTarget)) setOpen(false); }}>
    <button ref={trigger} className="view-trigger text-button" aria-haspopup="menu" aria-expanded={open} aria-controls={open ? 'departure-view-menu' : undefined} onClick={() => setOpen(v => !v)} onKeyDown={e => { if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); setOpen(true); } }}>View: {departureViews[selected].short}<ChevronDown size={13} /></button>
    {open && <div id="departure-view-menu" className="view-menu" role="menu" aria-label="Departure view" onKeyDown={e => {
      const index = items.current.indexOf(document.activeElement as HTMLButtonElement);
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
      else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) {
        e.preventDefault();
        const next = e.key === 'Home' ? 0 : e.key === 'End' ? departureViews.length - 1 : (index + (e.key === 'ArrowDown' ? 1 : -1) + departureViews.length) % departureViews.length;
        items.current[next]?.focus();
      }
    }}>{departureViews.map((view, index) => <button key={view.id} ref={el => { items.current[index] = el; }} role="menuitemradio" aria-checked={value === view.id} tabIndex={-1} onClick={() => { onChange(view.id); close(); }}><span>{view.label}</span>{value === view.id && <Check size={15} />}</button>)}</div>}
  </div>;
}
