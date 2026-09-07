import { storage } from './platform';
export type Preference = { direction: string; routes: string[] };
export function readPreferences(): Record<string, Preference> {
  const saved = storage.get<{ version: number; stations: Record<string, Preference> } | null>('preferences', null);
  if (saved?.version === 1 && saved.stations) return saved.stations;
  const stations = { [storage.get('station', '602')]: { direction: storage.get('direction', 'ALL'), routes: storage.get<string[]>('routes', []) } };
  storage.set('preferences', { version: 1, stations });
  return stations;
}
