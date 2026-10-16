import type { SourceState, StopPrediction, Train } from '../shared/types';
import type { TrackMapPlatform, TrackMapPoint, TrackMapSnapshot, TrackMapTopology, TrackMapTrain } from '../shared/track-map';
import { matchedTrip, serviceTime, type Schedules } from './schedules';

const LIVE_SECONDS = 90;
const EXPIRE_SECONDS = 300;
const MAX_HISTORY = 10000;
const MAX_PATH_CACHE = 2048;
const MAX_SEARCH_STEPS = 20000;
const MAX_PATH_EDGES = 512;
const subwayFeeds = new Set(['gtfs', 'gtfs-ace', 'gtfs-bdfm', 'gtfs-g', 'gtfs-jz', 'gtfs-l', 'gtfs-nqrw']);
const subwayRoutes = new Set(['1', '2', '3', '4', '5', '6', '6X', '7', '7X', 'A', 'B', 'C', 'D', 'E', 'F', 'FX', 'G', 'J', 'L', 'M', 'N', 'Q', 'R', 'W', 'Z', 'GS', 'FS', 'H', 'S']);
const validTime = (time: unknown, now: number): time is number => typeof time === 'number' && Number.isFinite(time) && time > 0 && time <= now;
const finitePoint = (p: TrackMapPoint) => Number.isFinite(p.x) && Number.isFinite(p.y);
const samePoint = (a: TrackMapPoint, b: TrackMapPoint) => a.x === b.x && a.y === b.y;
const clamp = (n: number) => Math.max(0, Math.min(1, n));
// Do not rely on caller keys that may omit the date or a frequency trip's start time.
const tripKey = (t: Train) => [t.feed, t.serviceDate || 'unknown', t.tripId, t.startTime || ''].join('|');
const positionKey = (t: Train) => JSON.stringify([t.position?.stopId, t.position?.status]);
const canceled = (t: Train) => ['CANCELED', 'DELETED'].includes(t.relationship || '');

interface Arc { id: string; from: string; to: string; points: TrackMapPoint[] }
interface Path { edgeIds: string[]; nodeIds: string[]; points: TrackMapPoint[]; lengths: number[]; length: number; signature: string }
interface Search { reachable: boolean; path?: Path; limited?: boolean }
interface Plan { path: Path; origin: string; target: string; startTime: number; fromProgress: number; arrivalTime: number; reason: string }
interface History {
	seen: number;
	observedAt: number | null;
	positionKey: string;
	stopped?: { stopId: string; nodeId: string; observedAt: number };
	plan?: Plan;
	blockedTarget?: string;
	row?: TrackMapTrain;
}

/** Stateful, conservative placement on directed revenue rails; all times are Unix seconds. */
export class TrackMapPlacement {
	private nodes = new Map<string, TrackMapPoint>();
	private platforms = new Map<string, TrackMapPlatform[]>();
	private stations = new Map<string, TrackMapTopology['stations'][number]>();
	private outgoing = new Map<string, Arc[]>();
	private incoming = new Map<string, Arc[]>();
	private paths = new Map<string, Search>();
	private history = new Map<string, History>();

	constructor(private readonly topology: TrackMapTopology) {
		for (const n of topology.nodes) if (finitePoint(n.point)) this.nodes.set(n.id, { ...n.point });
		for (const station of topology.stations) if (finitePoint(station.point)) {
			for (const stop of station.stopIds) this.stations.set(stop, station);
		}
		for (const p of topology.platforms) if (this.nodes.has(p.nodeId)) {
			const existing = this.platforms.get(p.stopId) || []; existing.push(p); this.platforms.set(p.stopId, existing);
		}
		const add = (arc: Arc) => {
			const out = this.outgoing.get(arc.from) || []; out.push(arc); this.outgoing.set(arc.from, out);
			const back = this.incoming.get(arc.to) || []; back.push(arc); this.incoming.set(arc.to, back);
		};
		for (const edge of topology.edges) {
			const from = this.nodes.get(edge.from), to = this.nodes.get(edge.to);
			// Never fill missing geometry with an invented straight line, or connect by proximity.
			if (!edge.revenue || !from || !to || edge.points.length < 2 || !edge.points.every(finitePoint) ||
				!samePoint(edge.points[0], from) || !samePoint(edge.points.at(-1)!, to)) continue;
			const points = edge.points.map(p => ({ ...p }));
			if (!points.some((p, i) => i > 0 && !samePoint(p, points[i - 1]))) continue;
			add({ id: edge.id, from: edge.from, to: edge.to, points });
			if (edge.bidirectional) add({ id: edge.id, from: edge.to, to: edge.from, points: [...points].reverse() });
		}
	}

	snapshot(trains: Iterable<Train>, sources: SourceState[], now: number, schedules?: Schedules): TrackMapSnapshot {
		if (!Number.isFinite(now) || now <= 0) throw new RangeError('Invalid snapshot time');
		const sourceIndex = new Map(sources.map(s => [s.id, s]));
		const unique = new Map<string, Train>();
		const conflicts = new Set<string>();
		const rank = (t: Train) => validTime(t.timestamp, now) ? t.timestamp : -Infinity;
		const vehicleRank = (t: Train) => validTime(t.position?.timestamp, now) ? t.position.timestamp : t.position?.timestamp == null ? rank(t) : -Infinity;
		const evidence = (t: Train) => JSON.stringify([positionKey(t), t.assigned, t.relationship,
			t.stops.map(s => [s.id, s.sequence, s.actualTrack, s.scheduledTrack, s.relationship])]);
		for (const t of trains) {
			if (!subwayFeeds.has(t.feed) || !subwayRoutes.has(t.route)) continue;
			const key = tripKey(t), prior = unique.get(key);
			if (!prior || rank(t) > rank(prior) || rank(t) === rank(prior) && vehicleRank(t) > vehicleRank(prior)) {
				unique.set(key, t); conflicts.delete(key);
			} else if (rank(t) === rank(prior) && vehicleRank(t) === vehicleRank(prior) && evidence(t) !== evidence(prior)) conflicts.add(key);
		}
		// Keep the evidence clock for a currently supplied cached vehicle, even after a long polling gap.
		for (const [key, h] of this.history) if (!unique.has(key) && now - h.seen >= EXPIRE_SECONDS) this.history.delete(key);
		const rows: TrackMapTrain[] = [];
		for (const [key, train] of unique) {
			const row = this.place(key, conflicts.has(key) ? { ...train, position: undefined } : train, sourceIndex.get(train.feed), now, schedules);
			if (conflicts.has(key)) row.reason = 'Conflicting duplicate observations; no occupied rail asserted';
			rows.push(row);
		}
		while (this.history.size > MAX_HISTORY) this.history.delete(this.history.keys().next().value!);
		return {
			schemaVersion: 1, mapVersion: this.topology.mapVersion, pdfSha256: this.topology.pdfSha256,
			generatedAt: now, sources, trains: rows,
			coverage: {
				placed: rows.filter(t => t.placement === 'track').length,
				uncertain: rows.filter(t => t.placement === 'near-stop').length,
				unplaced: rows.filter(t => t.placement === 'unplaced').length,
			},
		};
	}

	private place(key: string, t: Train, source: SourceState | undefined, now: number, schedules?: Schedules): TrackMapTrain {
		let h = this.history.get(key);
		const fingerprint = positionKey(t);
		let observedAt: number | null = null;
		if (t.position) {
			if (t.position.timestamp != null) observedAt = validTime(t.position.timestamp, now) ? t.position.timestamp : null;
			// The feed header is never a substitute for an unknown vehicle evidence clock.
			else observedAt = h?.positionKey === fingerprint ? h.observedAt : null;
		}
		const feedTime = validTime(t.timestamp, now) ? t.timestamp : null;
		const sourceTime = validTime(source?.timestamp, now) ? source.timestamp : null;
		const evidenceTime = observedAt != null && feedTime != null && sourceTime != null ? Math.min(observedAt, feedTime, sourceTime) : null;
		const staleAt = evidenceTime == null ? null : evidenceTime + LIVE_SECONDS;
		const expiresAt = evidenceTime == null ? null : evidenceTime + EXPIRE_SECONDS;
		const freshness: TrackMapTrain['freshness'] = expiresAt == null || now >= expiresAt ? 'unavailable' : now >= staleAt! || !!source?.error ? 'stale' : 'live';
		const stopId = t.position?.stopId;
		const station = stopId ? this.stations.get(stopId) : undefined;
		const row: TrackMapTrain = {
			key, feed: t.feed, route: t.route, destination: t.destination, direction: t.direction,
			stopId, stationId: station?.stationId, status: t.position?.status,
			trackBasis: 'unknown', positionBasis: 'unknown', placement: 'unplaced',
			observedAt, feedTimestamp: Number.isFinite(t.timestamp) ? t.timestamp : 0, staleAt, expiresAt, freshness,
		};
		if (!h) { h = { seen: now, observedAt, positionKey: fingerprint }; this.history.set(key, h); }
		h.seen = now;
		const finish = (reason?: string) => {
			if (reason) row.reason = reason;
			h!.row = structuredClone(row); return row;
		};
		if (canceled(t) || t.assigned === false) {
			h.plan = undefined; h.stopped = undefined; h.blockedTarget = undefined;
			return finish(canceled(t) ? 'Trip canceled or deleted' : 'Trip explicitly unassigned');
		}
		if (!t.position || !stopId || observedAt == null || freshness === 'unavailable') {
			h.plan = undefined; h.stopped = undefined;
			return finish(!t.position ? 'No vehicle observation; future trip is not an active marker' : freshness === 'unavailable' ? 'Position or source evidence unavailable or expired' : 'Invalid vehicle observation time');
		}
		// A failed source must not advance a previously displayed vehicle even if its header changed.
		if (source?.error && h.row?.point) {
			const previous = h.row;
			row.point = this.heldPoint(h, now); row.placement = previous.placement;
			row.trackBasis = previous.trackBasis; row.positionBasis = previous.positionBasis;
			row.trackCode = previous.trackCode; row.stopId = previous.stopId; row.stationId = previous.stationId; row.status = previous.status;
			row.observedAt = previous.observedAt; row.staleAt = previous.staleAt; row.expiresAt = previous.expiresAt;
			row.feedTimestamp = previous.feedTimestamp;
			if (row.expiresAt == null || now >= row.expiresAt) {
				row.freshness = 'unavailable'; row.placement = 'unplaced'; delete row.point;
			}
			return finish('Source error; frozen at last displayed position');
		}
		if (source?.error) {
			h.plan = undefined; h.stopped = undefined;
			if (station) { row.point = { ...station.point }; row.placement = 'near-stop'; }
			return finish('Source error; no previously placed vehicle to advance');
		}
		// Older vehicle observations must not overwrite a newer position or restart its clock.
		if (h.observedAt != null && observedAt < h.observedAt && h.row) {
			const previous = structuredClone(h.row);
			previous.point = this.heldPoint(h, now);
			delete previous.motion;
			previous.freshness = previous.expiresAt == null || now >= previous.expiresAt ? 'unavailable' : previous.staleAt == null || now >= previous.staleAt ? 'stale' : 'live';
			if (previous.freshness === 'unavailable') { previous.placement = 'unplaced'; delete previous.point; }
			previous.reason = 'Out-of-order vehicle observation ignored'; return previous;
		}
		h.observedAt = observedAt; h.positionKey = fingerprint;
		const indices = t.stops.flatMap((s, i) => s.id === stopId ? [i] : []);
		// An occurrence cannot be guessed for loops with repeated stop IDs and no sequence in VehiclePosition.
		const index = indices.length === 1 ? indices[0] : -1;
		const stop = index >= 0 ? t.stops[index] : undefined;
		const near = (reason: string) => {
			if (station) { row.point = { ...station.point }; row.placement = 'near-stop'; }
			return finish(reason);
		};
		const interrupt = () => {
			if (h!.plan) { h!.stopped = undefined; h!.blockedTarget = stopId; }
			h!.plan = undefined;
		};
		if (indices.length > 1) { interrupt(); return near('Ambiguous repeated stop occurrence'); }
		if (stop?.relationship === 'SKIPPED') { interrupt(); return near('Reported vehicle stop is skipped; no occupied platform asserted'); }
		const originNode = h.stopped && h.stopped.stopId !== stopId && h.stopped.observedAt < observedAt ? h.stopped.nodeId : undefined;
		const platform = this.resolve(t, index, stopId, originNode);
		const code = stop?.actualTrack?.trim() || stop?.scheduledTrack?.trim();
		row.trackCode = code || undefined;
		if (platform) row.trackBasis = stop?.actualTrack?.trim() ? 'reported' : stop?.scheduledTrack?.trim() ? 'scheduled' : 'inferred';
		if (t.position.status === 'STOPPED_AT') {
			h.plan = undefined; h.blockedTarget = undefined;
			if (!platform) { h.stopped = undefined; return near('Stop track is unmapped or ambiguous'); }
			row.point = { ...this.nodes.get(platform.nodeId)! }; row.placement = 'track'; row.positionBasis = 'reported';
			// A newly accepted stop supersedes the old origin even when too stale to prove departure.
			h.stopped = freshness === 'live' ? { stopId, nodeId: platform.nodeId, observedAt } : undefined;
			return finish('Vehicle reported stopped at the mapped platform');
		}
		if (!['INCOMING_AT', 'IN_TRANSIT_TO'].includes(t.position.status || '')) {
			interrupt(); return near('Vehicle status does not establish a segment or platform position');
		}
		if (!platform) {
			if (h.plan) { h.plan = undefined; h.stopped = undefined; h.blockedTarget = stopId; }
			return near('Target stop track is unmapped or ambiguous');
		}
		const arrival = stop?.arrival ?? stop?.departure;
		if (typeof arrival !== 'number' || !Number.isFinite(arrival) || arrival <= 0) {
			return near('No finite target ETA for bounded motion');
		}
		if (h.plan && h.plan.target !== stopId) {
			h.plan = undefined; h.stopped = undefined; h.blockedTarget = stopId;
			return near('Next reported stop changed without an observed departure; segment continuity unknown');
		}
		let candidate: Plan | undefined;
		if (h.stopped && h.stopped.stopId !== stopId && observedAt > h.stopped.observedAt && now - h.stopped.observedAt < EXPIRE_SECONDS) {
			const path = this.segment(t, h.stopped.stopId, h.stopped.nodeId, index, platform.nodeId);
			if (path) candidate = { path, origin: h.stopped.stopId, target: stopId, startTime: observedAt, fromProgress: 0, arrivalTime: arrival, reason: 'Estimated progress from observed departure and current target ETA' };
		}
		if (!candidate && !h.plan && h.blockedTarget !== stopId && freshness === 'live') {
			candidate = this.scheduledPlan(t, index, platform, arrival, schedules);
		}
		const previous = h.plan;
		if (previous?.target === stopId) {
			// A cold-start duration remains evidence on subsequent polls, without rematching schedules.
			if (!candidate && !h.stopped) {
				const path = this.segment(t, previous.origin, previous.path.nodeIds[0], index, platform.nodeId);
				if (path) candidate = { ...previous, path };
			}
			if (!candidate || candidate.path.signature !== previous.path.signature) {
				h.plan = undefined; h.stopped = undefined; h.blockedTarget = stopId;
				return near('Reroute or disconnected correction; waiting for new departure evidence');
			}
			candidate = previous;
			if (freshness === 'live' && arrival !== previous.arrivalTime) {
				const progress = this.progress(previous, Math.min(now, h.row?.staleAt ?? now));
				candidate = { ...previous, fromProgress: progress, startTime: now, arrivalTime: Math.max(now, arrival) };
			}
		}
		if (h.blockedTarget === stopId || !candidate || freshness !== 'live' && !previous) { h.plan = undefined; return near('No observed departure or unique scheduled segment duration; held near reported stop'); }
		h.plan = candidate;
		const sampleTime = Math.min(now, staleAt!);
		const progress = this.progress(candidate, sampleTime);
		row.point = this.point(candidate.path, progress); row.placement = 'track';
		row.trackBasis = 'inferred'; row.positionBasis = 'estimated';
		if (freshness === 'live' && !source?.error && candidate.arrivalTime > now && progress < 1) {
			const endTime = Math.min(candidate.arrivalTime, staleAt!);
			if (endTime > now) row.motion = {
				edgeIds: [...candidate.path.edgeIds], points: candidate.path.points.map(p => ({ ...p })),
				fromProgress: progress, toProgress: this.progress(candidate, endTime), startTime: now, endTime,
			};
		}
		return finish(candidate.reason);
	}

	private candidates(stopId: string, stop?: StopPrediction): TrackMapPlatform[] {
		const code = stop?.actualTrack?.trim() || stop?.scheduledTrack?.trim();
		const platforms = this.platforms.get(stopId) || [];
		// A partial topology's sole reviewed platform is not proof of physical uniqueness.
		// Only applicable code-backed platforms can support a precise rail endpoint.
		return code ? platforms.filter(p => p.trackCodes.includes(code)) : [];
	}

	private resolve(t: Train, index: number, stopId: string, originNode?: string): TrackMapPlatform | undefined {
		const stop = index >= 0 ? t.stops[index] : undefined;
		let candidates = this.candidates(stopId, stop);
		if (candidates.length === 1) return candidates[0];
		if (index < 0 || !candidates.length) return;
		if (originNode) candidates = candidates.filter(p => {
			const result = this.path(originNode, p.nodeId); return result.reachable || result.limited;
		});
		const before = t.stops.slice(0, index).reverse().find(s => s.relationship !== 'SKIPPED');
		const after = t.stops.slice(index + 1).find(s => s.relationship !== 'SKIPPED');
		for (const [neighbor, preceding] of [[before, true], [after, false]] as const) {
			if (!neighbor) continue;
			const others = this.candidates(neighbor.id, neighbor);
			if (!others.length) continue;
			candidates = candidates.filter(p => others.some(other => {
				const result = preceding ? this.path(other.nodeId, p.nodeId) : this.path(p.nodeId, other.nodeId);
				return result.reachable || result.limited;
			}));
		}
		return candidates.length === 1 ? candidates[0] : undefined;
	}

	private scheduledPlan(t: Train, index: number, platform: TrackMapPlatform, arrival: number, schedules?: Schedules): Plan | undefined {
		if (!schedules || index < 0 || !t.serviceDate || !/^\d{8}$/.test(t.serviceDate)) return;
		const candidates = new Map<string, { origin: string; duration: number }>();
		for (const feed of schedules.feeds) {
			const matched = matchedTrip(feed, t); if (!matched) continue;
			const { trip, pattern } = matched;
			const occurrences = pattern.stops.flatMap((id, i) => id === platform.stopId ? [i] : []);
			if (occurrences.length !== 1 || occurrences[0] === 0) continue;
			const target = occurrences[0];
			const previous = t.stops.slice(0, index).reverse().find(s => s.relationship !== 'SKIPPED');
			const originIndex = previous ? pattern.stops.lastIndexOf(previous.id, target - 1) : target - 1;
			if (originIndex < 0 || pattern.stops.indexOf(pattern.stops[originIndex]) !== originIndex) continue;
			const from = trip.times[originIndex], to = trip.times[target];
			if (typeof from !== 'number' || typeof to !== 'number' || !Number.isFinite(from) || !Number.isFinite(to)) continue;
			const duration = serviceTime(t.serviceDate, to) - serviceTime(t.serviceDate, from);
			if (!Number.isFinite(duration) || duration <= 0 || duration > 3600) continue;
			const origin = pattern.stops[originIndex];
			candidates.set(JSON.stringify([origin, duration, pattern.stops.slice(originIndex, target + 1)]), { origin, duration });
		}
		if (candidates.size !== 1) return;
		const { origin, duration } = [...candidates.values()][0];
		const originStop = t.stops.slice(0, index).find(s => s.id === origin && s.relationship !== 'SKIPPED');
		const paths = this.candidates(origin, originStop).flatMap(p => {
			const path = this.segment(t, origin, p.nodeId, index, platform.nodeId); return path ? [path] : [];
		});
		if (paths.length !== 1) return;
		return { path: paths[0], origin, target: platform.stopId, startTime: arrival - duration, fromProgress: 0, arrivalTime: arrival,
			reason: 'Estimated progress using uniquely matched scheduled segment duration and live target ETA' };
	}

	/** Every applicable intermediate live stop is a waypoint; skipped stops are not rail constraints. */
	private segment(t: Train, origin: string, from: string, targetIndex: number, to: string): Path | undefined {
		if (targetIndex < 0) return;
		const origins = t.stops.flatMap((s, i) => s.id === origin ? [i] : []);
		if (origins.length > 1 || origins.length === 1 && origins[0] >= targetIndex) return;
		const start = origins[0] ?? -1;
		const waypoints = [from];
		for (let i = start + 1; i < targetIndex; i++) {
			if (t.stops[i].relationship === 'SKIPPED') continue;
			const platform = this.resolve(t, i, t.stops[i].id);
			if (!platform) return;
			waypoints.push(platform.nodeId);
		}
		waypoints.push(to);
		const paths: Path[] = [];
		for (let i = 1; i < waypoints.length; i++) {
			const path = this.path(waypoints[i - 1], waypoints[i]).path;
			if (!path) return;
			paths.push(path);
		}
		if (paths.length === 1) return paths[0];
		const nodeIds = paths.flatMap((p, i) => i ? p.nodeIds.slice(1) : p.nodeIds);
		if (new Set(nodeIds).size !== nodeIds.length) return;
		const points = paths.flatMap((p, i) => i ? p.points.slice(1) : p.points);
		const lengths = [0];
		for (let i = 1; i < points.length; i++) lengths.push(lengths[i - 1] + Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y));
		return { nodeIds, points, lengths, length: lengths.at(-1)!, edgeIds: paths.flatMap(p => p.edgeIds), signature: paths.map(p => p.signature).join('|') };
	}

	/** Clients have already interpolated between polls; freezing must not rewind that window. */
	private heldPoint(history: History, now: number): TrackMapPoint | undefined {
		const row = history.row;
		if (!row?.point) return;
		if (row.motion && history.plan) {
			const time = Math.min(now, row.motion.endTime, row.staleAt ?? now);
			return this.point(history.plan.path, this.progress(history.plan, time));
		}
		return { ...row.point };
	}

	private progress(plan: Plan, now: number): number {
		if (now <= plan.startTime) return plan.fromProgress;
		if (plan.arrivalTime <= plan.startTime) return 1;
		return plan.fromProgress + (1 - plan.fromProgress) * clamp((now - plan.startTime) / (plan.arrivalTime - plan.startTime));
	}

	private point(path: Path, progress: number): TrackMapPoint {
		const distance = clamp(progress) * path.length;
		for (let i = 1; i < path.points.length; i++) if (path.lengths[i] >= distance) {
			const span = path.lengths[i] - path.lengths[i - 1], f = span > 0 ? (distance - path.lengths[i - 1]) / span : 0;
			return { x: path.points[i - 1].x + (path.points[i].x - path.points[i - 1].x) * f,
				y: path.points[i - 1].y + (path.points[i].y - path.points[i - 1].y) * f };
		}
		return { ...path.points.at(-1)! };
	}

	/** Find exactly one simple directed path, never a guessed shortest path through a junction. */
	private path(from: string, to: string): Search {
		if (from === to) return { reachable: true };
		const key = JSON.stringify([from, to]), cached = this.paths.get(key); if (cached) return cached;
		const save = (result: Search) => {
			if (this.paths.size >= MAX_PATH_CACHE) this.paths.delete(this.paths.keys().next().value!);
			this.paths.set(key, result); return result;
		};
		const reachable = new Set([to]), queue = [to];
		let steps = 0;
		for (let i = 0; i < queue.length; i++) {
			for (const arc of this.incoming.get(queue[i]) || []) {
				if (++steps > MAX_SEARCH_STEPS) return save({ reachable: false, limited: true });
				if (!reachable.has(arc.from)) { reachable.add(arc.from); queue.push(arc.from); }
			}
		}
		if (!reachable.has(from)) return save({ reachable: false });
		let found: Arc[] | undefined, count = 0, limited = false;
		const visited = new Set([from]), arcs: Arc[] = [];
		const walk = (node: string) => {
			if (node === to) { count++; if (!found) found = [...arcs]; return; }
			if (arcs.length >= MAX_PATH_EDGES) { limited = true; return; }
			for (const arc of this.outgoing.get(node) || []) {
				if (++steps > MAX_SEARCH_STEPS) { limited = true; return; }
				if (count > 1 || limited) return;
				if (!reachable.has(arc.to) || visited.has(arc.to)) continue;
				visited.add(arc.to); arcs.push(arc); walk(arc.to); arcs.pop(); visited.delete(arc.to);
			}
		};
		walk(from);
		if (count !== 1 || limited || !found) return save({ reachable: count > 0, limited });
		const points: TrackMapPoint[] = [];
		for (const arc of found) for (const p of arc.points) if (!points.length || !samePoint(points.at(-1)!, p)) points.push(p);
		const lengths = [0];
		for (let i = 1; i < points.length; i++) lengths.push(lengths[i - 1] + Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y));
		const length = lengths.at(-1)!;
		if (!Number.isFinite(length) || length <= 0) return save({ reachable: true });
		return save({ reachable: true, path: { points, lengths, length, nodeIds: [from, ...found.map(a => a.to)], edgeIds: found.map(a => a.id), signature: JSON.stringify(found.map(a => [a.id, a.from, a.to])) } });
	}
}
