import React, { lazy, Suspense, useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import './styles.css';
import './fleet.css';
import { base } from './platform';
import { leaveBoard } from './analytics';

const Stats = lazy(() => import('./Stats'));
function Router() {
  const [stats, setStats] = useState(() => location.pathname.replace(/\/$/, '') === base + 'stats');
  useEffect(() => { const pop = () => setStats(location.pathname.replace(/\/$/, '') === base + 'stats'); window.addEventListener('popstate', pop); return () => window.removeEventListener('popstate', pop); }, []);
  useEffect(() => { if (stats) leaveBoard(); }, [stats]);
  return stats ? <Suspense fallback={<p role="status">Loading statistics…</p>}><Stats /></Suspense> : <App />;
}
createRoot(document.getElementById('root')!).render(<React.StrictMode><Router /></React.StrictMode>);
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => { navigator.serviceWorker.register(base + 'sw.js', { scope: base }).catch(() => {}); });
}
