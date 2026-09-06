import { useCallback, useEffect, useState } from 'react';
import type { Board } from '../shared/types';
import { api, storage } from './platform';

export function useBoard(id: string) {
  const [state, setState] = useState<{ board?: Board; cached: boolean; error: string }>({ board: storage.get<Board | undefined>('board:' + id, undefined), cached: true, error: '' });
  const [refreshKey, setRefreshKey] = useState(0);
  const refresh = useCallback(() => setRefreshKey(v => v + 1), []);
  useEffect(() => {
    const controller = new AbortController();
    let active = true, busy = false;
    setState({ board: storage.get<Board | undefined>('board:' + id, undefined), cached: true, error: '' });
    const update = async () => {
      if (busy || document.hidden) return;
      busy = true;
      try {
        const board = await api<Board>(`stations/${encodeURIComponent(id)}/board`, controller.signal);
        if (!active) return;
        setState({ board, cached: false, error: '' });
        storage.set('board:' + id, board);
        const recent = [id, ...storage.get<string[]>('cachedStations', []).filter(s => s !== id)].slice(0, 8);
        for (const old of storage.get<string[]>('cachedStations', [])) if (!recent.includes(old)) {
          try { localStorage.removeItem('sfn:board:' + old); } catch { /* Storage may be disabled. */ }
        }
        storage.set('cachedStations', recent);
      } catch (error) {
        if (active) setState(s => ({ ...s, cached: true, error: navigator.onLine ? 'Feed connection interrupted. Retrying…' : 'Offline · showing your last saved board' }));
      } finally { busy = false; }
    };
    void update();
    const timer = setInterval(update, 10000);
    const offline = () => setState(s => ({ ...s, cached: true, error: 'Offline · showing your last saved board' }));
    document.addEventListener('visibilitychange', update);
    window.addEventListener('online', update); window.addEventListener('offline', offline);
    return () => { active = false; controller.abort(); clearInterval(timer); document.removeEventListener('visibilitychange', update); window.removeEventListener('online', update); window.removeEventListener('offline', offline); };
  }, [id, refreshKey]);
  return { ...state, board: state.board?.station.id === id ? state.board : undefined, refresh };
}
