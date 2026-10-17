import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { concatenatePaths, distance, flattenCommands, project, selectSubpath, sourcePathId, trimPathEnd, trimPathStart, type SourceReference } from '../scripts/track-map/topology';

const read = (path: string) => JSON.parse(readFileSync(new URL(`../${path}`, import.meta.url), 'utf8'));
const fragment = read('data/track-map/fragments/flushing.json');
const annotations = read('data/track-map/annotations.json');
const topology = read('data/track-map/nyc-2.6.8-v1.json');
const snapshots = read('data/track-map/track-code-evidence.json').snapshots;
const required = ['701', '702', '705', '718', '719', '720', '721', '723', '724', '725', '726'];
const source = (ref: SourceReference, tolerance = 0.005) => {
	const raw = fragment.sourcePaths[sourcePathId(ref)];
	assert.ok(raw, `missing exact source object ${JSON.stringify(ref)}`);
	const points = flattenCommands(typeof ref === 'number' ? raw.commands : selectSubpath(raw.commands, ref.subpath), tolerance);
	return (typeof ref === 'number' ? ref < 0 : ref.reverse) ? points.reverse() : points;
};
const geometry = (rail: any) => {
	const paths = rail.paths.map((ref: SourceReference) => source(ref));
	for (const index of rail.trimEndToNext ?? []) paths[index] = trimPathEnd(source(rail.paths[index], 0.005), paths[index + 1][0]);
	return concatenatePaths(paths, 0.03);
};
const rails = () => new Map<string, any>(fragment.review.rails.map((r: any) => [r.id, { ...r, points: geometry(r) }]));

test('all eleven remaining Flushing parts and both directions have specific acceptance or unresolved evidence', () => {
	assert.deepEqual(fragment.review.stationParts.slice().sort(), required);
	assert.deepEqual(fragment.review.stopReviews.map((s: any) => s.stopId).sort(), required.flatMap(id => [`${id}N`, `${id}S`]).sort());
	for (const row of fragment.review.stopReviews) {
		assert.ok(row.status && row.evidence && row.impact);
		assert.ok(topology.stations.some((s: any) => s.stopIds.includes(row.stopId)));
		assert.ok(row.physicalRailIds.length);
	}
});

test('source identity retains entire native objects, commands and styles with explicit subpaths', () => {
	assert.equal(fragment.sourceSha256, 'b28f75397b2e7b6ba0b67db6ea2181800baa0254a48261252f3d55c4f2b17c71');
	for (const [id, raw] of Object.entries<any>(fragment.sourcePaths)) {
		assert.equal(raw.id, Number(id));
		assert.equal(createHash('sha256').update(JSON.stringify(raw)).digest('hex'), fragment.review.sourcePathHashes[id]);
	}
	for (const rail of rails().values()) {
		assert.equal(rail.maxJoinGap, 0.03);
		assert.ok(rail.points.length >= 2 && rail.evidence);
		for (const point of rail.points) assert.ok(point.x >= 0 && point.y >= 0 && point.x <= 7344 && point.y <= 11540.6);
		for (const ref of rail.paths) if (fragment.sourcePaths[sourcePathId(ref)].commands.filter((c: any) => c.op === 'm').length > 1) assert.equal(typeof ref, 'object');
	}
	// Explicit separation is required even when two movetos share the same endpoint.
	const commands = [{op: 'm', p: [0, 0]}, {op: 'l', p: [1, 0]}, {op: 'm', p: [1, 0]}, {op: 'l', p: [2, 0]}];
	assert.throws(() => flattenCommands(commands), /multiple subpaths/);
	assert.deepEqual(flattenCommands(selectSubpath(commands, 1)), [{x: 1, y: 0}, {x: 2, y: 0}]);
	assert.throws(() => selectSubpath(commands, 2), /missing source subpath/);
});

test('optional raw extraction verifies exact object identity independently of fragment hashes', {skip: !process.env.TRACK_MAP_EXTRACTED}, () => {
	const raw = JSON.parse(readFileSync(process.env.TRACK_MAP_EXTRACTED!, 'utf8'));
	for (const [id, path] of Object.entries(fragment.sourcePaths)) assert.deepEqual(path, raw.paths.find((p: any) => p.id === Number(id)));
});

test('source gaps retain measured endpoints and cannot become joins or tolerate missing paint', () => {
	assert.ok(fragment.gaps.length > 5);
	for (const gap of fragment.gaps) {
		const a = source(gap.from.path).at(gap.from.endpoint === 'start' ? 0 : -1)!;
		const b = gap.candidateTo.endpoint ? source(gap.candidateTo.path).at(gap.candidateTo.endpoint === 'start' ? 0 : -1)! : project(a, source(gap.candidateTo.path, gap.projectionTolerance ?? 0.005)).point;
		assert.deepEqual(gap.sourceEndpoints, [a, b]);
		assert.ok(Math.abs(distance(a, b) - gap.distance) < 1e-8, gap.id);
		assert.ok(gap.distance > 0.03 && gap.evidence && gap.impact, gap.id);
		assert.throws(() => concatenatePaths([[{x: a.x - 1, y: a.y}, a], [b, {x: b.x + 1, y: b.y}]], 0.03), /source endpoint gap/);
	}
	for (const rail of rails().values()) geometry(rail);
});

test('reviewed physical junctions meet named rails and never join stacked levels or crossed corridors', () => {
	const rs = rails();
	for (const j of fragment.review.physicalJunctions) {
		const p = source(j.sourcePath).at(j.endpoint === 'start' ? 0 : -1)!;
		assert.equal(j.maxProjectionDistance, 0.03);
		assert.ok(j.evidence && j.operationalTraversal);
		for (const id of j.rails) assert.ok(project(p, rs.get(id).points).distance <= 0.03, `${j.id}/${id}`);
	}
	assert.deepEqual(fragment.review.queensboroLevels.map((r: any) => r.level).sort(), ['lower', 'upper']);
	const levels = fragment.review.queensboroLevels.map((r: any) => rs.get(r.railId));
	assert.ok(levels.every((r: any) => r.platformParts.includes('718')));
	assert.ok(!fragment.review.physicalJunctions.some((j: any) => levels.every((r: any) => j.rails.includes(r.id))));
	assert.ok(fragment.review.omittedCrossings.length >= 4);
	for (const crossing of fragment.review.omittedCrossings) assert.ok(crossing.sourcePathIds.length >= 2 && crossing.evidence && crossing.reason);
});

test('center inventory has platforms only at eligible stations and no duplicates of accepted local chains', () => {
	const existing = new Set(annotations.chains.filter((c: any) => c.corridor === 'flushing' && !fragment.chains.some((f: any) => f.id === c.id)).flatMap((c: any) => c.paths.map(sourcePathId)));
	for (const c of fragment.chains) {
		assert.ok(!c.paths.some((ref: SourceReference) => existing.has(sourcePathId(ref))), `duplicate canonical geometry ${c.id}`);
		assert.deepEqual(annotations.chains.find((a: any) => a.id === c.id), c, 'reviewed fragment chain is integrated exactly');
		assert.ok(c.direction !== 'B' && !c.bidirectional, 'no inferred bidirectional terminal or center operation');
		assert.ok(c.physicalCodeEvidence && c.witnessStopIds.length);
		for (const part of c.platformParts) assert.ok(required.includes(part));
	}
	for (const rail of rails().values()) if (rail.role === 'center') assert.ok(!rail.platformParts.includes('705') && !rail.platformParts.includes('716'));
});

test('exact frozen witnesses and resolved/unresolved crosswalks are unique and exhaustive', () => {
	for (const e of fragment.codeEvidence) {
		assert.ok(snapshots.some((s: any) => s.sha256 === e.feedSha256 && s.feedTimestamp === e.feedTimestamp && s.fetchedAt === e.fetchedAt && s.observations.some((o: any) => o.route === e.route && o.stopId === e.stopId && o.actualTrack === e.actualTrack && o.scheduledTrack === e.scheduledTrack)));
	}
	const existing = new Set(topology.platforms.filter((p: any) => !fragment.chains.some((c: any) => p.nodeId.startsWith(`${c.id}:`))).flatMap((p: any) => p.trackCodes.map((code: string) => `${p.stopId}:${code}`)));
	const accepted = new Set<string>();
	for (const c of fragment.chains) for (const part of c.platformParts) for (const dir of c.platformDirections?.[part] ?? [c.direction]) {
		const code = c.codes?.[part] ?? c.code, key = `${part}${dir}:${code}`;
		assert.ok(code && !existing.has(key) && !accepted.has(key), `duplicate/conflicting crosswalk ${key}`);
		accepted.add(key);
		assert.equal(topology.platforms.filter((p: any) => p.stopId === `${part}${dir}` && p.trackCodes.includes(code)).length, 1, `canonical pair ${key}`);
		assert.ok(fragment.review.resolvedCrosswalks.some((r: any) => r.stopId === `${part}${dir}` && r.code === code && r.chainId === c.id));
	}
	const all = new Set<string>();
	for (const row of [...fragment.review.resolvedCrosswalks, ...fragment.review.unresolvedCrosswalks]) {
		const key = `${row.stopId}:${row.code}`;
		assert.ok(!all.has(key), `resolved/unresolved conflict ${key}`); all.add(key);
		assert.ok(row.evidence && row.impact);
	}
	const expected = new Set<string>(fragment.codeEvidence.filter((e: any) => required.includes(e.stopId.slice(0, -1))).flatMap((e: any) => [e.actualTrack, e.scheduledTrack].filter(Boolean).map((code: string) => `${e.stopId}:${code}`)));
	for (const key of expected) assert.ok(all.has(key), `unaccounted observation ${key}`);
	for (const key of all) assert.ok(expected.has(key) || accepted.has(key), `unwitnessed unresolved pair ${key}`);
	assert.deepEqual(fragment.review.resolvedCrosswalks.map((r: any) => `${r.stopId}:${r.code}`).sort(), [...accepted].sort());
});

test('terminal inventory preserves all three Main St and both Hudson Yards faces without turnbacks', () => {
	for (const [part, count] of [['701', 3], ['726', 2]] as const) {
		const faces = fragment.review.terminalFaces.filter((f: any) => f.partId === part);
		assert.equal(faces.length, count);
		assert.equal(new Set(faces.map((f: any) => f.railId)).size, count);
		for (const f of faces) assert.ok(f.sourcePath && f.evidence && f.operationalLimit);
	}
	for (const j of fragment.junctions) assert.ok(!j.id.includes('turnback'));
	assert.ok(fragment.review.unresolvedOperatingMoves.some((r: any) => r.stopId === '726N'));
});

test('rail precision resolves the reviewed Queensboro branch without increasing the seam bound', () => {
	assert.equal(fragment.review.requiredFlatteningTolerance, 0.005);
	const endpoint = source(8599).at(-1)!;
	assert.ok(project(endpoint, source(8600, 0.05)).distance > 0.03);
	assert.ok(project(endpoint, source(8600, 0.005)).distance < 0.006);
	assert.ok(project(endpoint, source(8600, 0.0001)).distance < 0.005);
	for (const chain of fragment.chains) assert.equal(chain.flatteningTolerance, 0.005);
	assert.match(fragment.review.precisionScope, /preserve.*station anchors/);
});

test('every reviewed overlap uses an existing successor endpoint while preserving original raw objects', () => {
	assert.equal(fragment.review.overlapReviews.length, 5);
	for (const overlap of fragment.review.overlapReviews) {
		const endpoint = source(overlap.next)[0];
		assert.deepEqual(endpoint, overlap.nextSourceEndpoint);
		assert.ok(Math.abs(project(endpoint, source(overlap.from, 0.005)).distance - overlap.projectionDistance) < 1e-9);
		assert.ok(overlap.projectionDistance <= 0.03);
		const trimmed = trimPathEnd(source(overlap.from, 0.005), endpoint);
		assert.deepEqual(trimmed.at(-1), endpoint);
	}
	assert.throws(() => flattenCommands(fragment.sourcePaths['2304'].commands), /multiple subpaths/);
	assert.ok(!fragment.review.rails.some((r: any) => r.paths.some((ref: SourceReference) => sourcePathId(ref) === 2304)), 'excluded multi-moveto nonrevenue tails must not become passenger rails');
});

test('optional raw inventory audit accounts for every magenta one-point source object without accepting color as a code', {skip: !process.env.TRACK_MAP_EXTRACTED}, () => {
	const raw = JSON.parse(readFileSync(process.env.TRACK_MAP_EXTRACTED!, 'utf8'));
	const candidates = raw.paths.filter((p: any) => p.paint === 'S' && p.width === 1 && Math.abs(p.stroke[0] - 0.576) < 0.001).map((p: any) => p.id).sort((a: number, b: number) => a - b);
	assert.deepEqual(fragment.review.sourceObjectDecisions.map((r: any) => r.sourcePathId).sort((a: number, b: number) => a - b), candidates);
	assert.equal(candidates.length, 78);
	for (const row of fragment.review.sourceObjectDecisions) {
		assert.ok(row.reason);
		if (row.status === 'inventoried') assert.ok(row.railIds.length > 0);
		else assert.ok([1816, 1854, 2298, 2303].includes(row.sourcePathId));
	}
});

test('canonical Flushing integration preserves accepted anchors, directions and recorded disconnections', () => {
	const built = topology;
	assert.equal(createHash('sha256').update(JSON.stringify(built.stations)).digest('hex'), '6d01410ff4ecb3ccc7164a867e664e28ca0d3a7ef4316aefb50a450a6415c467', 'all475 checkpoint07 accepted anchor objects remain unchanged');
	const node = (stopId: string, code: string) => built.platforms.find((p: any) => p.stopId === stopId && p.trackCodes.includes(code))?.nodeId;
	const reachable = (from: string, to: string) => {
		assert.ok(from && to);
		const visited = new Set([from]), queue = [from];
		while (queue.length) {
			const current = queue.shift();
			for (const edge of built.edges) {
				const next = edge.from === current ? edge.to : edge.bidirectional && edge.to === current ? edge.from : undefined;
				if (next && !visited.has(next)) { visited.add(next); queue.push(next); }
			}
		}
		return visited.has(to);
	};
	assert.ok(reachable(node('701S', '1'), node('726S', '1')), 'source local1 runs toward Manhattan');
	assert.ok(!reachable(node('726S', '1'), node('701S', '1')), 'no terminal turnback creates opposite-direction local1');
	assert.ok(reachable(node('719N', '2'), node('705N', '2')), 'N reverses source traversal on local2');
	assert.ok(!reachable(node('720N', '2'), node('719N', '2')), 'Court Sq paint gap stays disconnected');
	assert.ok(!reachable(node('702S', 'M'), node('718S', '1')), 'center-west source gap is not a local1 shortcut');
	assert.ok(reachable(node('705N', '2'), node('701N', '2')), 'reviewed head overlap preserves incoming local2');
	assert.equal(node('701N', '2'), node('701S', '2'));
	assert.equal(node('726N', '1'), node('726S', '1'));
	assert.ok(!reachable(node('701S', '2'), node('705S', '1')), 'terminal alias does not create a departure crossover');
	assert.equal(node('705S', 'M'), undefined);
});


test('Main Street head overlap clips only the original local2 prefix while terminal aliases preserve direction',()=>{
	const review=fragment.review.headOverlapReview,endpoint=source(review.previousPath).at(-1)!;
	assert.ok(project(endpoint,source(review.trimmedPath,0.005)).distance<0.001);
	assert.ok(project(endpoint,source(review.trimmedPath,0.0001)).distance<0.001);
	const clipped=trimPathStart(source(review.trimmedPath,0.005),endpoint);
	assert.deepEqual(clipped[0],endpoint);
	assert.deepEqual(clipped.at(-1),source(review.trimmedPath).at(-1));
	assert.deepEqual(fragment.chains.find((c:any)=>c.id==='flushing-east-2').trimStartFromPrevious,[2]);
	assert.equal(fragment.review.unresolvedCrosswalks.length,0);
	assert.equal(fragment.review.unresolvedOperatingMoves.length,2);
});
