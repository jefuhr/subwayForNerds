import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { concatenatePaths, distance, flattenCommands, project, selectSubpath, sourcePathId, type SourceReference } from '../scripts/track-map/topology';

const read = (path: string) => JSON.parse(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8'));
const fragment = read('data/track-map/fragments/jamaica-myrtle.json');
const topology = read('data/track-map/nyc-2.6.8-v1.json');
const observations = read('data/track-map/track-code-evidence.json').snapshots.flatMap((s: any) => s.observations);
const catalog = read('data/stations.json').filter((s: any) => ['Jamaica', 'Myrtle Av'].includes(s.line));
const source = (ref: SourceReference) => {
	const p = fragment.sourcePaths[sourcePathId(ref)];
	assert.ok(p, `missing source path ${JSON.stringify(ref)}`);
	const points = flattenCommands(typeof ref === 'number' ? p.commands : selectSubpath(p.commands, ref.subpath));
	return (typeof ref === 'number' ? ref < 0 : ref.reverse) ? points.reverse() : points;
};
const rails = () => new Map<string, any>(fragment.review.rails.map((r: any) => [r.id, { ...r, points: concatenatePaths(r.paths.map(source), 0.03) }]));

test('Jamaica/Myrtle fragment accounts for all 35 accepted anchors and all 70 nominal directions', () => {
	assert.equal(catalog.length, 35);
	assert.deepEqual(fragment.review.stationParts.slice().sort(), catalog.map((s: any) => s.id).sort());
	assert.deepEqual(fragment.review.stopReviews.map((s: any) => s.stopId).sort(), catalog.flatMap((s: any) => [`${s.id}N`, `${s.id}S`]).sort());
	for (const row of fragment.review.stopReviews) {
		assert.ok(row.evidence && row.status && row.impact);
		assert.ok(topology.stations.some((s: any) => s.stopIds.includes(row.stopId)));
	}
});

test('native source objects retain exact commands and styles, bounded geometry and explicit subpaths', () => {
	assert.equal(fragment.sourceSha256, 'b28f75397b2e7b6ba0b67db6ea2181800baa0254a48261252f3d55c4f2b17c71');
	for (const [id, raw] of Object.entries<any>(fragment.sourcePaths)) {
		assert.equal(raw.id, Number(id));
		assert.equal(createHash('sha256').update(JSON.stringify(raw)).digest('hex'), fragment.review.sourcePathHashes[id]);
		assert.equal(raw.paint, 'S'); assert.equal(raw.width, 1);
	}
	for (const rail of rails().values()) {
		assert.equal(rail.maxJoinGap, 0.03);
		assert.ok(rail.points.length >= 2);
		assert.ok(rail.evidence.length > 0);
		for (const p of rail.points) assert.ok(p.x >= 0 && p.y >= 0 && p.x <= 7344 && p.y <= 11540.6);
	}
	assert.throws(() => flattenCommands(fragment.sourcePaths['8023'].commands), /multiple subpaths/);
	assert.ok(fragment.review.rails.some((r: any) => r.paths.some((p: any) => p.pathId === 8023 && p.subpath === 1)));
});

test('optional raw extraction proves full source path identity rather than approximate reconstruction', { skip: !process.env.TRACK_MAP_EXTRACTED }, () => {
	const raw = JSON.parse(readFileSync(process.env.TRACK_MAP_EXTRACTED!, 'utf8'));
	for (const [id, path] of Object.entries(fragment.sourcePaths)) assert.deepEqual(path, raw.paths.find((p: any) => p.id === Number(id)));
});

test('every reviewed seam is physical, gaps stay disconnected and no tolerance is raised', () => {
	for (const rail of rails().values()) {
		for (let i = 1; i < rail.paths.length; i++) assert.ok(distance(source(rail.paths[i - 1]).at(-1)!, source(rail.paths[i])[0]) <= 0.03, rail.id);
	}
	assert.ok(fragment.gaps.length >= 4);
	for (const gap of fragment.gaps) {
		const a = source(gap.from.path).at(gap.from.endpoint === 'start' ? 0 : -1)!;
		const b = source(gap.candidateTo.path).at(gap.candidateTo.endpoint === 'start' ? 0 : -1)!;
		assert.ok(distance(a, b) > 0.03);
		assert.ok(Math.abs(distance(a, b) - gap.distance) < 1e-8);
		assert.deepEqual(gap.sourceEndpoints, [a, b]);
		assert.ok(gap.evidence && gap.impact);
	}
});

test('Myrtle junction connects each reviewed branch to its actual receiving rail, never the crossed parallel', () => {
	const rs = rails();
	const merges = fragment.review.physicalJunctions.filter((j: any) => j.id.startsWith('myrtle-'));
	assert.equal(merges.length, 2);
	for (const j of merges) {
		const endpoint = source(j.sourcePath).at(j.endpoint === 'start' ? 0 : -1)!;
		assert.equal(j.maxProjectionDistance, 0.03);
		for (const id of j.rails) assert.ok(project(endpoint, rs.get(id).points).distance <= j.maxProjectionDistance, `${j.id}/${id}`);
	}
	const northBranch = merges.find((j: any) => sourcePathId(j.sourcePath) === 8197);
	assert.ok(northBranch.rails.includes('broadway-center'));
	assert.ok(!northBranch.rails.includes('broadway-northeast-local'));
	const southBranch = merges.find((j: any) => sourcePathId(j.sourcePath) === 8198);
	assert.ok(southBranch.rails.includes('broadway-southwest-local'));
	const seen = new Set(['myrtle-north-physical']);
	for (let i = 0; i < 4; i++) for (const j of merges) if (j.rails.some((r: string) => seen.has(r))) j.rails.forEach((r: string) => seen.add(r));
	assert.ok(seen.has('broadway-center'));
	assert.ok(!seen.has('myrtle-south-physical'));
	assert.ok(!seen.has('broadway-northeast-local'));
	assert.ok(!seen.has('canarsie'));
});

test('center rail has no platforms at Broadway local-only stops or grade-separated station parts', () => {
	const center = rails().get('broadway-center');
	for (const id of ['J28', 'J29', 'J30', 'J31', 'M12', 'M13', 'M14']) assert.ok(!center.platformParts.includes(id));
	assert.deepEqual(center.platformParts.slice().sort(), ['J27', 'M11']);
	for (const rail of rails().values()) for (const part of rail.platformParts) assert.ok(catalog.some((s: any) => s.id === part));
});

test('code witnesses exactly match frozen route/stop/code observations and never fabricate missing directions', () => {
	const keys = new Set();
	for (const e of fragment.codeEvidence) {
		const key = `${e.route}:${e.stopId}:${e.actualTrack}:${e.scheduledTrack}`;
		assert.ok(!keys.has(key), `duplicate observation ${key}`); keys.add(key);
		assert.ok(observations.some((o: any) => o.route === e.route && o.stopId === e.stopId && o.actualTrack === e.actualTrack && o.scheduledTrack === e.scheduledTrack));
	}
	for (const stop of ['J28S', 'J29S', 'J30S', 'J31S']) assert.ok(!fragment.codeEvidence.some((e: any) => e.stopId === stop));
	const emitted = new Set();
	for (const c of fragment.chains) {
		assert.ok(c.direction !== 'B' && !c.bidirectional, 'shared J/M direction aliases are not reversible rails');
		for (const part of c.platformParts ?? c.stationParts) for (const direction of c.platformDirections?.[part] ?? [c.direction]) {
			const code = c.codes?.[part] ?? c.code, key = `${part}${direction}:${code}`;
			assert.ok(code && !emitted.has(key), `duplicate or conflicting crosswalk ${key}`); emitted.add(key);
			assert.ok(fragment.codeEvidence.some((e: any) => e.stopId === `${part}${direction}` && [e.actualTrack, e.scheduledTrack].includes(code)) || c.witnessStopIds?.length, `no direct or continuous witness ${key}`);
		}
	}
});


test('unresolved stop/code pairs are unique and cannot silently become active or conflicting physical mappings', () => {
	const seen = new Set<string>();
	const expected = new Set(fragment.codeEvidence.flatMap((e: any) => [e.actualTrack, e.scheduledTrack].filter(Boolean).map((code: string) => `${e.stopId}:${code}`)));
	for (const row of fragment.review.unresolvedCrosswalks) {
		const key = `${row.stopId}:${row.code}`;
		assert.ok(!seen.has(key), `duplicate/conflicting pair ${key}`); seen.add(key);
		assert.equal(row.status, 'physical-rail-unresolved');
		assert.ok(row.candidateRailIds.length >= 2);
		assert.equal(new Set(row.candidateRailIds).size, row.candidateRailIds.length);
		for (const id of row.candidateRailIds) assert.ok(rails().get(id).platformParts.includes(row.stopId.slice(0, -1)));
		assert.ok(row.witnesses.length > 0 && row.reason);
	}
	for (const row of fragment.review.resolvedCrosswalks) {
		const key = `${row.stopId}:${row.code}`;
		assert.ok(!seen.has(key), `resolved/unresolved conflict ${key}`);
		if (expected.has(key)) seen.add(key);
		assert.ok(row.evidence && fragment.chains.some((c: any) => c.id === row.chainId && c.physicalCodeEvidence));
		assert.ok(topology.platforms.some((p: any) => p.stopId === row.stopId && p.trackCodes.includes(row.code)));
	}
	assert.deepEqual([...seen].sort(), [...expected].sort());
	assert.equal(fragment.chains.length, 9);
	assert.deepEqual(fragment.junctions.map((j: any) => j.id).sort(), ['essex-north-bridge-merge', 'essex-south-bowery-merge', 'myrtle-local-branch']);
	assert.ok(!fragment.chains.some((c: any) => ['broadway-center', 'myrtle-north-physical'].includes(c.id)), 'ambiguous center operations are withheld');
});

test('all physical junction endpoints meet their named rails without converting inventory to directed train paths', () => {
	const rs = rails();
	for (const j of fragment.review.physicalJunctions) {
		const p = source(j.sourcePath).at(j.endpoint === 'start' ? 0 : -1)!;
		assert.equal(j.maxProjectionDistance, 0.03);
		for (const id of j.rails) assert.ok(project(p, rs.get(id).points).distance <= 0.03, `${j.id}/${id}`);
		assert.match(j.operationalTraversal, /unresolved/);
	}
});
