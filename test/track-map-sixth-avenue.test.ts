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
