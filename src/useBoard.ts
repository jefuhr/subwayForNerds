import { useEffect, useReducer } from 'react';
import type { Board } from '../shared/types';
import { api, storage } from './platform';

type Entry = { board?: Board; cached: boolean; error: string; checked: number };
const cache = new Map<string, Entry>();
const busy = new Set<string>();
const listeners = new Set<() => void>();
let selected = '', favorites: string[] = [], running = false;
const emit = () => listeners.forEach(fn => fn());
function entry(id: string) {
  if (!cache.has(id)) cache.set(id, { board: storage.get<Board | undefined>('board:' + id, undefined), cached: true, error: '', checked: 0 });
  return cache.get(id)!;
}
function persist() {
  const recent = [...cache.keys()].reverse().filter(id => !favorites.includes(id)).slice(0, 8);
  let ids = [...new Set([...favorites, ...recent])];
  for (const old of storage.get<string[]>('cachedStations', [])) if (!ids.includes(old)) {
    try { localStorage.removeItem('sfn:board:' + old); } catch { /* optional storage */ }
  }
  for (const id of ids) {
    const board = entry(id).board;
    if (!board) continue;
    while (true) {
      try { localStorage.setItem('sfn:board:' + id, JSON.stringify(board)); break; }
      catch {
        const evict = recent.pop();
        if (!evict) break;
        ids = ids.filter(x => x !== evict);
        try { localStorage.removeItem('sfn:board:' + evict); } catch { break; }
        if (evict === id) break;
      }
    }
  }
  storage.set('cachedStations', ids);
  for (const id of cache.keys()) if (!favorites.includes(id) && !recent.includes(id) && id !== selected && !busy.has(id)) cache.delete(id);
}
function pump() {
  if (!running || document.hidden || !navigator.onLine) return;
  for (const id of new Set([selected, ...favorites])) {
    if (!id || busy.has(id) || Date.now() - entry(id).checked < (id === selected ? 10000 : 30000)) continue;
    if (busy.size >= 3) break;
    busy.add(id);
    void api<Board>(`stations/${encodeURIComponent(id)}/board`).then(board => {
      cache.set(id, { board, cached: false, error: '', checked: Date.now() }); persist();
    }).catch(() => {
      cache.set(id, { ...entry(id), checked: Date.now(), cached: true, error: navigator.onLine ? 'Feed connection interrupted. Retrying…' : 'Offline · showing your last saved board' });
    }).finally(() => { busy.delete(id); emit(); pump(); });
  }
}
export function useBoard(id: string, saved: string[]) {
  const [, render] = useReducer(n => n + 1, 0);
  useEffect(() => {
    listeners.add(render); running = true;
    const change = () => { if (!navigator.onLine) for (const e of cache.values()) { e.cached = true; e.error = 'Offline · showing your last saved board'; } emit(); pump(); };
    const timer = setInterval(pump, 1000);
    document.addEventListener('visibilitychange', change);
    window.addEventListener('online', change); window.addEventListener('offline', change);
    return () => { running = false; listeners.delete(render); clearInterval(timer); document.removeEventListener('visibilitychange', change); window.removeEventListener('online', change); window.removeEventListener('offline', change); };
  }, []);
  useEffect(() => { selected = id; favorites = saved; entry(id); pump(); }, [id, saved]);
  const state = entry(id);
  return { ...state, refresh: () => { state.checked = 0; pump(); } };
}
