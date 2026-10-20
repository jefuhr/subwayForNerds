import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { TrackMapTopology } from '../shared/track-map';

const topology = (): TrackMapTopology => JSON.parse(readFileSync(new URL('../data/track-map/nyc-2.6.8-v1.json', import.meta.url), 'utf8'));
function platform(t: TrackMapTopology, stop: string, code: string) {
	const p = t.platforms.find(p => p.stopId === stop && p.trackCodes.includes(code));
	assert.ok(p, `Missing reviewed ${stop}/${code}`);
	return p.nodeId;
}
function reachable(t: TrackMapTopology, from: string, to: string) {
	const pending = [from], seen = new Set<string>();
	for (const node of pending) {
		if (node === to) return true;
		if (seen.has(node)) continue;
		seen.add(node);
		for (const edge of t.edges) {
			if (edge.revenue && edge.from === node) pending.push(edge.to);
			if (edge.revenue && edge.bidirectional && edge.to === node) pending.push(edge.from);
		}
	}
	return false;
}

test('NYCT-anchored Sixth Avenue tracks remain separate and express rails have no local-only platforms', () => {
	const t = topology();
	const faces = [platform(t, 'D17S', 'B1'), platform(t, 'D17S', 'B3'), platform(t, 'D17N', 'B4'), platform(t, 'D17N', 'B2')];
	assert.equal(new Set(faces).size, 4);
	assert.ok(reachable(t, platform(t, 'D16S', 'B3'), platform(t, 'D17S', 'B3')));
	assert.ok(reachable(t, platform(t, 'D17N', 'B4'), platform(t, 'D16N', 'B4')));
	assert.ok(!reachable(t, faces[0], faces[1]));
	assert.ok(!t.platforms.some(p => ['D18N', 'D18S', 'D19N', 'D19S'].includes(p.stopId) && p.trackCodes.some(c => c === 'B3' || c === 'B4')));
});

test('Sixth Avenue local source rails preserve direction through Rockefeller and the 57 Street code change', () => {
	const t = topology();
	assert.ok(reachable(t, platform(t, 'D15S', 'B1'), platform(t, 'D19S', 'B1')));
	assert.ok(!reachable(t, platform(t, 'D19S', 'B1'), platform(t, 'D15S', 'B1')));
	assert.ok(reachable(t, platform(t, 'D20N', 'B2'), platform(t, 'B10N', 'B6')));
});

test('Lower Sixth Avenue local fragments reach York Street without bridging the West 4 Street painted gaps', () => {
	const t = topology();
	assert.ok(reachable(t, platform(t, 'D21S', 'B1'), platform(t, 'F18S', 'B1')));
	assert.ok(reachable(t, platform(t, 'F18N', 'B2'), platform(t, 'D21N', 'B2')));
	assert.ok(!reachable(t, platform(t, 'D20S', 'B1'), platform(t, 'D21S', 'B1')));
	assert.ok(!reachable(t, platform(t, 'D21N', 'B2'), platform(t, 'D20N', 'B2')));
	assert.ok(reachable(t, platform(t, 'D21S', 'B3'), platform(t, 'D22S', 'B3')));
	assert.ok(reachable(t, platform(t, 'D22N', 'B4'), platform(t, 'D21N', 'B4')));
});

test('Directly witnessed terminal aliases reuse physical nodes without inventing reverse traversal', () => {
	const t = topology();
	assert.equal(platform(t, '101S', '4'), platform(t, '101N', '4'));
	assert.equal(platform(t, '701N', 'M'), platform(t, '701S', 'M'));
	assert.equal(platform(t, '702N', 'M'), platform(t, '702S', 'M'));
	assert.ok(!reachable(t, platform(t, '101S', '4'), platform(t, '103N', '4')));
	assert.ok(!reachable(t, platform(t, '702N', 'M'), platform(t, '701N', 'M')));
});

test('Brighton north fragments keep Atlantic and 7 Avenue on witnessed paired rails without crossing the Prospect Park paint break', () => {
	const t = topology();
	assert.ok(reachable(t, platform(t, 'D24S', 'A3'), platform(t, 'D25S', 'A3')));
	assert.ok(reachable(t, platform(t, 'D25N', 'A4'), platform(t, 'D24N', 'A4')));
	assert.ok(!reachable(t, platform(t, 'D25S', 'A3'), platform(t, 'D26S', 'A3')));
	assert.ok(!reachable(t, platform(t, 'D24S', 'A3'), platform(t, 'D25N', 'A4')));
});

test('a rerouted C reported between Sixth Avenue core stops stays on Sixth Avenue rails', async () => {
	const { TrackMapPlacement } = await import('../server/track-map');
	const t = topology(), at = 1800000000;
	const sources = [{ id: 'gtfs-ace', timestamp: at, fetchedAt: at, error: null }];
	for (const code of ['B1', 'B3']) {
		const engine = new TrackMapPlacement(t);
		const train = {
			key: `rerouted-C-${code}`, feed: 'gtfs-ace', tripId: 'rerouted-C', route: 'C', destination: 'Euclid Av', direction: 'SOUTH', timestamp: at, alerts: [],
			position: { stopId: 'D16S', name: '42 St-Bryant Pk', status: 'STOPPED_AT', timestamp: at },
			stops: ['D16S', 'D17S'].map((id, index) => ({ id, name: id, arrival: at + index * 120, departure: at + index * 120 + 10, actualTrack: code })),
		};
		const origin = engine.snapshot([train], sources, at).trains[0];
		assert.equal(origin.placement, 'track'); assert.equal(origin.trackBasis, 'reported');
		assert.deepEqual(origin.point, t.nodes.find(n => n.id === platform(t, 'D16S', code))!.point);
		train.timestamp += 10;
		train.position = { stopId: 'D17S', name: '34 St-Herald Sq', status: 'IN_TRANSIT_TO', timestamp: at + 10 };
		const moving = engine.snapshot([train], sources, at + 10).trains[0];
		assert.ok(moving.motion, `Expected reviewed Sixth Avenue motion on ${code}`);
		assert.ok(moving.motion.edgeIds.every(id => id.startsWith('sixth-')));
		assert.ok(moving.motion.edgeIds.every(id => !id.includes('eighth')));
		for (const stopId of ['A27S', 'A28S']) for (const eighth of t.platforms.filter(p => p.stopId === stopId)) {
			assert.notDeepEqual(moving.point, t.nodes.find(n => n.id === eighth.nodeId)!.point);
		}
	}
});
