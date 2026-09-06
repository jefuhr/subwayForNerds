import { useEffect, useRef } from 'react';
import { X } from 'lucide-react';

export default function Modal({ title, eyebrow, children, close }: { title: string; eyebrow?: string; children: React.ReactNode; close: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current!;
    const previous = document.activeElement as HTMLElement | null;
    dialog.showModal();
    const viewport = window.visualViewport;
    const syncViewport = () => {
      if (!viewport) return;
      // Mobile browsers keep a dialog anchored to the layout viewport while the
      // software keyboard shrinks the visual viewport. Move the sheet above it
      // and cap its height so the focused control remains reachable.
      const keyboardBottom = Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop);
      dialog.style.setProperty('--keyboard-bottom', `${keyboardBottom}px`);
      dialog.style.setProperty('--visual-viewport-height', `${viewport.height}px`);
      const active = document.activeElement;
      if (active instanceof HTMLElement && dialog.contains(active)) {
        requestAnimationFrame(() => active.scrollIntoView({ block: 'nearest', inline: 'nearest' }));
      }
    };
    syncViewport();
    viewport?.addEventListener('resize', syncViewport);
    viewport?.addEventListener('scroll', syncViewport);
    window.addEventListener('resize', syncViewport);
    return () => {
      viewport?.removeEventListener('resize', syncViewport);
      viewport?.removeEventListener('scroll', syncViewport);
      window.removeEventListener('resize', syncViewport);
      dialog.close();
      previous?.focus();
    };
  }, []);
  return <dialog ref={ref} className="sheet" onCancel={close} onClick={e => { if (e.target === ref.current) close(); }}>
    <div className="sheet-inner">
      <header className="sheet-heading"><div>{eyebrow && <span className="eyebrow">{eyebrow}</span>}<h2>{title}</h2></div><button className="icon-button" aria-label="Close panel" onClick={close}><X size={20} /></button></header>
      {children}
    </div>
  </dialog>;
}
