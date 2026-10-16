import { readFileSync } from 'node:fs';
import type { TrackMapPoint, TrackMapTopology } from '../shared/track-map';

export const TRACK_MAP_VERSION = 'nyc-2.6.8-v1';

/** Treat bundled assets as a fallible input; map failure must not stop boards. */
export function validateTrackMapTopology(value: TrackMapTopology): TrackMapTopology {
	if (value.schemaVersion !== 1 || !/^[A-Za-z0-9._-]{1,80}$/.test(value.mapVersion) || !/^[a-f0-9]{64}$/.test(value.pdfSha256)
		|| !Number.isFinite(value.page?.width) || !Number.isFinite(value.page?.height) || value.page.width <= 0 || value.page.height <= 0) throw new Error('Invalid map identity');
	const point = (p: TrackMapPoint) => p && Number.isFinite(p.x) && Number.isFinite(p.y) && p.x >= 0 && p.y >= 0 && p.x <= value.page.width && p.y <= value.page.height;
	const ids = (items: { id: string }[]) => {
		if (!Array.isArray(items) || items.some(v => typeof v.id !== 'string' || !v.id)) throw new Error('Invalid map IDs');
		const unique = new Set(items.map(v => v.id));
		if (unique.size !== items.length) throw new Error('Duplicate map IDs');
		return unique;
	};
	const nodes = ids(value.nodes); ids(value.edges); ids(value.platforms); ids(value.stations);
	if (value.nodes.some(n => !point(n.point)) || value.stations.some(s => !point(s.point) || !Array.isArray(s.stopIds)
		|| s.stopIds.some(id => typeof id !== 'string' || !id))) throw new Error('Invalid map coordinates');
	if (value.edges.some(e => !nodes.has(e.from) || !nodes.has(e.to) || !Array.isArray(e.points) || e.points.length < 2 || e.points.some(p => !point(p))
		|| typeof e.bidirectional !== 'boolean' || typeof e.revenue !== 'boolean')) throw new Error('Invalid map edge');
	const nodePoints = new Map(value.nodes.map(n => [n.id, n.point]));
	const equal = (a: TrackMapPoint, b: TrackMapPoint) => a.x === b.x && a.y === b.y;
	if (value.edges.some(e => !equal(e.points[0], nodePoints.get(e.from)!) || !equal(e.points.at(-1)!, nodePoints.get(e.to)!)
		|| e.points.every(p => equal(p, e.points[0])))) throw new Error('Disconnected or zero-length map geometry');
	const stopIds = value.stations.flatMap(s => s.stopIds), stops = new Set(stopIds);
	if (stops.size !== stopIds.length) throw new Error('Duplicate station stop');
	if (value.platforms.some(p => !nodes.has(p.nodeId) || !stops.has(p.stopId) || !Array.isArray(p.trackCodes) || p.trackCodes.some(t => typeof t !== 'string' || !t))) throw new Error('Invalid map platform');
	const crosswalks = new Set<string>(), mapped = new Set<string>();
	for (const platform of value.platforms) for (const code of platform.trackCodes) {
		const key = JSON.stringify([platform.stopId, code]);
		if (crosswalks.has(key)) throw new Error('Conflicting map track crosswalk');
		crosswalks.add(key); mapped.add(platform.stopId);
	}
	const coverageIds = (items: string[]) => {
		if (!Array.isArray(items) || items.some(id => typeof id !== 'string' || !id) || new Set(items).size !== items.length) throw new Error('Invalid map coverage');
		return new Set(items);
	};
	const declared = coverageIds(value.coverage?.mappedStopIds), unresolved = coverageIds(value.coverage?.unresolvedStopIds);
	if (declared.size !== mapped.size || [...mapped].some(id => !declared.has(id)) || [...declared].some(id => unresolved.has(id))
		|| stopIds.some(id => !declared.has(id) && !unresolved.has(id))) throw new Error('Inconsistent map coverage');
	return value;
}

export function loadTrackMapTopology(): TrackMapTopology | undefined {
	try {
		return validateTrackMapTopology(JSON.parse(readFileSync(new URL(`../data/track-map/${TRACK_MAP_VERSION}.json`, import.meta.url), 'utf8')));
	} catch { return undefined; }
}
