/** The public .nerds v1 contract. Keep Swift and the shared fixture in lockstep. */
export const MAX_SETTINGS_BYTES = 1024 * 1024;
export type StationSettings = { direction: string; routes: string[]; view: 'track' | 'direction' | 'family' | 'corridor' | 'service' };
export type Settings = {
	favorites: string[]; theme: string; stations: Record<string, StationSettings>;
	widgets: { matchAppFilters: boolean; stations: Record<string, StationSettings>; display: {
		fields: string[]; compact: boolean; trainsPerDirection: number; timeStyle: 'countdown' | 'minutes' | 'clock';
	} };
};
export type NerdsFile = { format: 'subways-for-nerds'; version: 1; exportedAt: string; lastStation: string; settings: Settings };
export type SettingsRevision = { revision: number; settings: Settings | null };
export type Conflict = { path: string; local: unknown; remote: unknown };
export type Resolutions = Record<string, 'local' | 'remote'>;
export const widgetFields = ['stationName', 'destination', 'track', 'service', 'carType', 'carCount', 'carNumbers', 'location', 'updatedAt', 'refreshButton', 'groupHeaders'];
export function defaults(): Settings {
	return { favorites: [], theme: 'subway', stations: {}, widgets: { matchAppFilters: false, stations: {}, display: {
		fields: ['stationName', 'destination', 'track', 'carType', 'updatedAt', 'refreshButton', 'groupHeaders'].sort(), compact: true, trainsPerDirection: 0, timeStyle: 'countdown',
	} } };
}
function invalid(): never { throw new Error('This is not a valid Subway Nerds settings file.'); }
function object(v: unknown): Record<string, any> { if (!v || typeof v !== 'object' || Array.isArray(v)) invalid(); return v as Record<string, any>; }
function keys(v: Record<string, any>, names: string[]) { if (Object.keys(v).some(k => !names.includes(k)) || names.some(k => !Object.hasOwn(v, k))) invalid(); }
function string(v: unknown): string { if (typeof v !== 'string' || !v.length || v.length > 128 || /[\u0000-\u001f]/.test(v)) invalid(); return v; }
function strings(v: unknown, max = 2000): string[] { if (!Array.isArray(v) || v.length > max) invalid(); const a = v.map(string); if (new Set(a).size !== a.length) invalid(); return a; }
function boolean(v: unknown): boolean { if (typeof v !== 'boolean') invalid(); return v; }
function stations(value: unknown): Record<string, StationSettings> {
	const entries = Object.entries(object(value)); if (entries.length > 2000) invalid();
	return Object.fromEntries(entries.map(([id, raw]) => {
		string(id); if (['__proto__', 'constructor', 'prototype'].includes(id)) invalid();
		const v = object(raw); keys(v, ['direction', 'routes', 'view']);
		if (!['ALL', 'NORTH', 'SOUTH', 'TO_NY', 'TO_NJ', 'UNKNOWN'].includes(v.direction) || !['track', 'direction', 'family', 'corridor', 'service'].includes(v.view)) invalid();
		return [id, { direction: v.direction, routes: strings(v.routes, 128).sort(), view: v.view }];
	}));
}
export function validateSettings(value: unknown): Settings {
	if (new TextEncoder().encode(JSON.stringify(value)).length > MAX_SETTINGS_BYTES) throw new Error('Settings files must be smaller than 1 MiB.');
	const v = object(value); keys(v, ['favorites', 'theme', 'stations', 'widgets']);
	const w = object(v.widgets); keys(w, ['matchAppFilters', 'stations', 'display']);
	const d = object(w.display); keys(d, ['fields', 'compact', 'trainsPerDirection', 'timeStyle']);
	const fields = strings(d.fields, widgetFields.length).sort();
	if (fields.some(f => !widgetFields.includes(f)) || !Number.isInteger(d.trainsPerDirection) || d.trainsPerDirection < 0 || d.trainsPerDirection > 8 || !['countdown', 'minutes', 'clock'].includes(d.timeStyle)) invalid();
	return { favorites: strings(v.favorites), theme: string(v.theme), stations: stations(v.stations), widgets: {
		matchAppFilters: boolean(w.matchAppFilters), stations: stations(w.stations), display: {
			fields, compact: boolean(d.compact), trainsPerDirection: d.trainsPerDirection, timeStyle: d.timeStyle,
		},
	} };
}
export function decodeNerds(text: string): NerdsFile {
	if (new TextEncoder().encode(text).length > MAX_SETTINGS_BYTES) throw new Error('Settings files must be smaller than 1 MiB.');
	let v: Record<string, any>; try { v = object(JSON.parse(text)); } catch { return invalid(); }
	if (v.format !== 'subways-for-nerds') invalid();
	if (v.version !== 1) throw new Error('This settings version is not supported. Update Subway Nerds and try again.');
	keys(v, ['format', 'version', 'exportedAt', 'lastStation', 'settings']);
	if (typeof v.exportedAt !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(v.exportedAt) || !Number.isFinite(Date.parse(v.exportedAt))) invalid();
	return { format: 'subways-for-nerds', version: 1, exportedAt: v.exportedAt, lastStation: string(v.lastStation), settings: validateSettings(v.settings) };
}
export function encodeNerds(settings: Settings, lastStation: string): string {
	const text = JSON.stringify({ format: 'subways-for-nerds', version: 1, exportedAt: new Date().toISOString(), lastStation: string(lastStation), settings: validateSettings(settings) }, null, 2);
	decodeNerds(text); return text;
}
export function equal(a: unknown, b: unknown): boolean {
	if (a === b) return true;
	if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) return false;
	const x = Object.entries(a), y = Object.entries(b);
	return x.length === y.length && x.every(([k, v]) => Object.hasOwn(b, k) && equal(v, (b as any)[k]));
}
export function mergeSettings(base: Settings, local: Settings, remote: Settings, choices: Resolutions = {}): { settings: Settings; conflicts: Conflict[] } {
	const conflicts: Conflict[] = [];
	const record = (v: any) => v !== null && typeof v === 'object' && !Array.isArray(v);
	const merge = (b: any, l: any, r: any, path: string): any => {
		if (equal(l, r) || equal(b, r)) return l;
		if (equal(b, l)) return r;
		if (record(l) && record(r) && (b === undefined || record(b))) {
			const result: Record<string, unknown> = {};
			for (const k of new Set([...Object.keys(b || {}), ...Object.keys(l), ...Object.keys(r)])) {
				const v = merge(b?.[k], l[k], r[k], path + '/' + k.replaceAll('~', '~0').replaceAll('/', '~1'));
				if (v !== undefined) Object.defineProperty(result, k, { value: v, enumerable: true, writable: true, configurable: true });
			}
			return result;
		}
		if (choices[path]) return choices[path] === 'local' ? l : r;
		conflicts.push({ path, local: l, remote: r }); return l;
	};
	// Favorites are membership edits, not competing replacements of an entire list.
	const ids = [...new Set([...remote.favorites, ...local.favorites, ...base.favorites])];
	const favorites = ids.filter(id => merge(base.favorites.includes(id), local.favorites.includes(id), remote.favorites.includes(id), '/favorites/' + id));
	const settings = merge({ ...base, favorites: [] }, { ...local, favorites: [] }, { ...remote, favorites: [] }, '');
	return { settings: validateSettings({ ...settings, favorites }), conflicts };
}
/** Human-readable changed paths, including additions/removals; shared by file previews. */
export function settingsChanges(before: Settings, after: Settings): Conflict[] {
	const result: Conflict[] = [];
	const walk = (a: any, b: any, path: string) => {
		if (equal(a, b)) return;
		if (a && b && typeof a === 'object' && typeof b === 'object' && !Array.isArray(a) && !Array.isArray(b)) {
			for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) walk(a[key], b[key], path ? path + ' / ' + key : key);
		} else result.push({ path, local: a, remote: b });
	};
	walk(before, after, ''); return result;
}
