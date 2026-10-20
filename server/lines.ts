import type { Station, StationPart, Train } from '../shared/types';
import { parentStop } from './catalog';
import trunks from '../data/trunks.json';
import { matchedTrip, type Schedules } from './schedules';

// Short physical platform segments stay separate from the train's actual trunk.
export function segmentName(part: StationPart, borough: string): string {
	// York Street is in Brooklyn but remains on the Sixth Avenue approach.
	if (part.id === 'F18') return '6 Av';
	// These shared junctions have platforms used by more than one branch.
	// Keep the trunk alone; area prefixes can still use the station name.
	if (['R30', 'D42', 'A41', 'A42'].includes(part.id)) return '';
	switch (part.line) {
		case '6th Av - Culver': return borough === 'M' ? '6 Av' : 'Culver';
		case 'Broadway - Brighton': return borough === 'M' ? 'Broadway' : 'Brighton';
		case '8th Av - Fulton St': return borough === 'M' ? '8 Av' : 'Fulton St';
		case 'Lenox - White Plains Rd': return borough === 'M' ? 'Lenox' : 'White Plains Rd';
		case 'Jamaica': return borough === 'M' ? 'Nassau' : 'Jamaica';
		case 'Broadway - 7Av': return '7 Av';
		case 'Lexington Av': return 'Lex';
		case 'Lexington - Shuttle': return '42 St Shuttle';
		case 'Queens - Archer': return 'Archer Av';
		case 'Sea Beach / West End / Culver / Brighton': return 'Coney Island';
		default: return part.line.replace(/\b(\d+)(?:st|nd|rd|th)\b/g, '$1');
	}
}

const trunkNames = new Set(trunks.map(trunk => trunk.name));
function trunkPath(train: Train, schedules?: Schedules, paths?: WeakMap<Train, Set<string>>): Set<string> {
	const cached = paths?.get(train);
	if (cached) return cached;
	let scheduled = train.scheduledPattern?.stops;
	if (!scheduled && schedules?.version === 2) {
		// Trip identity alone cannot prove a reroute; require compatible remaining stops.
		for (const name of ['gtfs_supplemented', 'gtfs_subway']) {
			const feed = schedules.feeds.find(feed => feed.name === name);
			const match = feed && matchedTrip(feed, train);
			if (!match) continue;
			let last = -1;
			const compatible = train.stops.filter(stop => stop.relationship !== 'SKIPPED').every(stop => {
				const index = match.pattern.stops.indexOf(stop.id, last + 1);
				if (index < 0) return false;
				last = index; return true;
			});
			if (compatible) { scheduled = match.pattern.stops; break; }
		}
	}
	const path = new Set([...train.stops.map(stop => stop.id), ...(scheduled || [])].map(parentStop));
	paths?.set(train, path);
	return path;
}
export function trunkLabel(train: Train, segment: string, stopId: string, schedules?: Schedules, paths?: WeakMap<Train, Set<string>>): string {
	const normal = trunks.find(trunk => trunk.routes.includes(train.route));
	if (!normal) return segment || 'Service pattern';
	if (!normal.stops.length) return normal.name;
	// Scheduled paths retain planned reroutes even after the core is behind us.
	// Without a matching scheduled trip or a core stop ahead, reroutes fall back.
	const path = trunkPath(train, schedules, paths);
	const matches = trunks.map(trunk => ({ trunk, count: trunk.stops.filter(stop => path.has(stop)).length }))
		.filter(match => match.count > 0);
	// At a core stop, the physical departure trunk wins even on a partial reroute.
	// Beyond the cores, a witnessed deviation wins over the normal route trunk.
	const departureTrunk = trunks.find(trunk => trunk.stops.includes(parentStop(stopId)));
	const deviations = matches.filter(match => match.trunk !== normal);
	const trunk = departureTrunk || deviations.sort((a, b) => b.count - a.count)[0]?.trunk || normal;
	if (!segment || segment === trunk.name || trunkNames.has(segment)) return trunk.name;
	return `${trunk.name}–${segment}`;
}

export function boardingArea(station: Station, part: StationPart, direction: string, track?: string): string {
	const regional = station.id.startsWith('path-') || station.departureMode === 'external';
	const physicalName = (p: StationPart) => segmentName(p, station.borough) || p.name;
	const multipleSegments = new Set(station.parts.map(physicalName)).size > 1;
	const prefix = regional ? part.line : multipleSegments ? physicalName(part) : '';
	return `${prefix ? `${prefix} · ` : ''}${direction}${track ? ` · Track ${track}` : ''}`;
}
