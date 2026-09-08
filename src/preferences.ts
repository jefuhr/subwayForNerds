import { validView, type DepartureView } from '../shared/departureGroups';
import { storage } from './platform';
export type Preference = { direction: string; routes: string[]; view: DepartureView };
export function readPreferences(): Record<string, Preference> {
  const saved = storage.get<{ version: number; stations: Record<string, Preference> } | null>('preferences', null);
  if (saved?.version === 1 && saved.stations) return Object.fromEntries(Object.entries(saved.stations).map(([id, preference]) => [id, { ...preference, view: validView(preference.view) }]));
  const stations = { [storage.get('station', '602')]: { direction: storage.get('direction', 'ALL'), routes: storage.get<string[]>('routes', []), view: 'track' as const } };
  storage.set('preferences', { version: 1, stations });
  return stations;
}
