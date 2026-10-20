import test from 'node:test';
import assert from 'node:assert/strict';
import { bundledCatalog } from '../server/catalog';
import { boardingArea, segmentName, trunkLabel } from '../server/lines';
import type { Train } from '../shared/types';
import trunks from '../data/trunks.json';

const at = (id: string) => {
	const station = bundledCatalog.find(s => s.parts.some(p => p.id === id))!;
	return { station, part: station.parts.find(p => p.id === id)! };
};
test('physical segment names cover borough boundaries, York Street and official ordinal names', () => {
	const cases: [string, string][] = [
		['D19', '6 Av'], ['F18', '6 Av'], ['F25', 'Culver'],
		['R20', 'Broadway'], ['D24', 'Brighton'], ['A27', '8 Av'], ['A45', 'Fulton St'],
		['224', 'Lenox'], ['222', 'White Plains Rd'], ['M19', 'Nassau'], ['M11', 'Jamaica'],
		['127', '7 Av'], ['635', 'Lex'], ['901', '42 St Shuttle'], ['G05', 'Archer Av'],
		['D43', 'Coney Island'], ['R31', '4 Av'], ['B04', '63 St'],
	];
	for (const [id, expected] of cases) {
		const { station, part } = at(id);
		assert.equal(segmentName(part, station.borough), expected, id);
	}
});
test('shuttle identity stays a shuttle name even if a synthetic path intersects another core', () => {
	assert.equal(trunkLabel({ route: 'GS', stops: [{ id: 'D16S' }] } as Train, '42 St Shuttle', 'D16S'), '42 St Shuttle');
});
test('regional boarding labels retain their current line prefix', () => {
	for (const station of bundledCatalog.filter(s => s.id.startsWith('path-') || s.departureMode === 'external')) {
		const part = station.parts[0];
		assert.equal(boardingArea(station, part, 'Northbound', '1'), `${part.line} · Northbound · Track 1`);
	}
});

test('a junction name is used only when a combined station needs a physical prefix', () => {
	const { station, part } = at('R30');
	const other = { ...at('D24').part };
	assert.equal(boardingArea({ ...station, parts: [part, other] }, part, 'Manhattan'), 'DeKalb Av · Manhattan');
});

const coreParts = new Map(bundledCatalog.flatMap(station => station.parts.map(part => [part.id, part] as const)));
test('every trunk core stop exists in the station catalog', () => {
	const missing = trunks.flatMap(trunk => trunk.stops.filter(stop => !coreParts.has(stop)).map(stop => `${trunk.name}: ${stop}`));
	assert.deepEqual(missing, []);
});
test('normal daytime routes at each core stop belong only to that trunk', () => {
	for (const trunk of trunks) for (const stop of trunk.stops) {
		const part = coreParts.get(stop);
		if (!part) continue; // The catalog-existence assertion reports missing stops separately.
		for (const route of part.routes) assert.ok(trunk.routes.includes(route), `${trunk.name} core ${stop} serves foreign route ${route}`);
	}
});
test('trunk cores never share a stop', () => {
	const seen = new Set<string>();
	for (const trunk of trunks) for (const stop of trunk.stops) {
		assert.ok(!seen.has(stop), `Repeated core stop ${stop}`);
		seen.add(stop);
	}
});
