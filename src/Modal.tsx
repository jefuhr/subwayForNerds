import { useEffect, useRef } from 'react';
import { X } from 'lucide-react';

export default function Modal({ title, eyebrow, children, close }: { title: string; eyebrow?: string; children: React.ReactNode; close: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current!;
    const previous = document.activeElement as HTMLElement | null;
    dialog.showModal();
    return () => { dialog.close(); previous?.focus(); };
  }, []);
  return <dialog ref={ref} className="sheet" onCancel={close} onClick={e => { if (e.target === ref.current) close(); }}>
    <div className="sheet-inner">
      <header className="sheet-heading"><div>{eyebrow && <span className="eyebrow">{eyebrow}</span>}<h2>{title}</h2></div><button className="icon-button" aria-label="Close panel" onClick={close}><X size={20} /></button></header>
      {children}
    </div>
  </dialog>;
}
