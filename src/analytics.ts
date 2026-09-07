import { base, storage } from './platform';
import type { AnalyticsEvent, EventName } from '../shared/analytics';
const uuid = () => crypto.randomUUID();
let browser = storage.get('browser', '') || uuid();
storage.set('browser', browser);
let session = storage.get('session', { id: '', last: 0 });
let queue: AnalyticsEvent[] = [], sending = false;
let lastStation = '';
const referrer = (() => { try { return new URL(document.referrer).hostname; } catch { return ''; } })();
function event(name: EventName, station?: string): AnalyticsEvent {
  return { id: uuid(), browser, session: session.id, name, ...(station ? { station } : {}), device: /iPad|Tablet/i.test(navigator.userAgent) ? 'tablet' : /Mobi/i.test(navigator.userAgent) ? 'phone' : 'desktop', referrer };
}
export function track(name: EventName, station?: string) {
  const now = Date.now();
  const shared = storage.get('session', session);
  if (shared.last > session.last) session = shared;
  if (!session.id || now - session.last >= 30 * 60000) {
    session = { id: uuid(), last: now }; queue.push(event('session_start'));
  }
  session.last = now; storage.set('session', session);
  queue.push(event(name, station)); queue = queue.slice(-100);
}
export function stationView(id: string) { if (lastStation !== id) { lastStation = id; track('station_view', id); } }
export function leaveBoard() { lastStation = ''; }
async function flush() {
  if (sending || !queue.length || !navigator.onLine) return;
  sending = true; const batch = queue.slice(0, 20);
  try {
    const response = await fetch(base + 'api/v1/analytics/events', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ events: batch }), keepalive: true, signal: AbortSignal.timeout(10000) });
    if (response.ok || response.status === 400 || response.status === 413) queue = queue.filter(e => !batch.some(b => b.id === e.id));
  } catch { /* retry in memory only */ } finally { sending = false; }
}
setInterval(() => { if (!document.hidden) void flush(); }, 5000);
window.addEventListener('online', () => void flush());
document.addEventListener('visibilitychange', () => { if (document.hidden) void flush(); });
window.addEventListener('pagehide', () => void flush());
