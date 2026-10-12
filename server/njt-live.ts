import { mkdir, open, readFile, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { unzipSync, strFromU8 } from 'fflate';
import { parse } from 'csv-parse/sync';
import type { Board, Departure, NjtState, SourceState, Station, StopPrediction, Train, VehiclePosition } from '../shared/types';
import { NJT_LINES } from '../shared/njt';
import { njtCatalog } from './njt';
import { decode } from './decode';

const BASE = 'https://pcsdata.njtransit.com/api/GTFSG2/';
const PROVIDER = 'njt-bus-g2' as const;
const PREDICTIONS = `${PROVIDER}-predictions`, POSITIONS = `${PROVIDER}-positions`;
const STALE_AFTER = 60, POSITION_MAX_AGE = 300;
const TOKEN_LIFETIME = 24 * 3600, AUTH_COOLDOWN = 3 * 3600;
const ROUTES: Record<string, string> = { HBLR: 'NJT-HBLR', NLR: 'NJT-NLR', RvLN: 'NJT-RIVER' };
const nowSeconds = () => Math.floor(Date.now() / 1000);
const epoch = (value: unknown): value is number => typeof value === 'number' && Number.isSafeInteger(value) && value > 0 && value < 100_000_000_000;
const text = (value: unknown): value is string => typeof value === 'string' && value.length > 0 && value.length <= 500;
const record = (value: any): value is Record<string, any> => !!value && typeof value === 'object' && !Array.isArray(value);
const serviceDate = (value: unknown): value is string => typeof value === 'string' && /^\d{8}$/.test(value);
const startTime = (value: unknown): value is string => typeof value === 'string' && /^\d{2,3}:[0-5]\d:[0-5]\d$/.test(value);
const state = (id: string, staleAfter = STALE_AFTER): SourceState => ({ id, timestamp: null, fetchedAt: null, error: null, staleAfter });
const keyFor = (trip: { trip_id: string; start_date?: string; start_time?: string }) =>
	`${PROVIDER}|${trip.start_date || 'unknown'}|${trip.trip_id}|${trip.start_time || ''}`;
const vehicleKey = (route: string, vehicleId: string) => `${PROVIDER}|${route}|${vehicleId}`;
// GTFS direction IDs are product conventions, not universal compass directions.
const direction = (route: string, id: string, destination: string): StaticTrip['direction'] => {
	if (route === 'NLR') {
		const terminal = destination.toUpperCase().trim().replace(/^NLR\s+/, '');
		if (['PENN STATION', 'NEWARK PENN STATION'].includes(terminal)) return 'SOUTH';
		if (['GROVE STREET', 'GROVE ST', 'BRANCH BROOK PARK', 'BROAD ST STATION', 'BROAD STREET STATION'].includes(terminal)) return 'NORTH';
		// Via-Penn trips change cardinal direction en route; retain the destination.
		return 'UNKNOWN';
	}
	return id !== '0' && id !== '1' ? 'UNKNOWN' : (route === 'HBLR' ? id === '1' : id === '0') ? 'NORTH' : 'SOUTH';
};

type StaticTrip = { id: string; routeId: string; route: string; destination: string; direction: 'NORTH' | 'SOUTH' | 'UNKNOWN' };
type StaticStop = { id: string; code?: string; name: string; stationId: string; route: string };
type StaticIdentity = { trips: Map<string, StaticTrip>; stops: Map<string, StaticStop>; routes: Set<string> };
type Detail = { train: Train; raw: unknown; source: { state: SourceState; header: unknown } };
type Options = { cacheDir: string; credentials?: { username: string; password: string }; fetcher?: typeof fetch; onUpdate?: () => void };

class NjtError extends Error {
	constructor(message: string, readonly status?: number) { super(message); }
}
const safeError = (error: unknown) => error instanceof NjtError ? error.message : 'NJT request failed';

function parseStatic(bytes: Uint8Array): StaticIdentity {
	// The production bus archive includes >200 MB of stop times and shapes. Do not
	// decompress them: scheduled times never supply predictions or movements.
	const files = unzipSync(bytes, { filter: file => ['routes.txt', 'trips.txt', 'stops.txt'].includes(path.posix.basename(file.name)) });
	const rows = (name: string): Record<string, string>[] => {
		const matches = Object.entries(files).filter(([file]) => path.posix.basename(file) === name);
		if (matches.length !== 1) throw new NjtError('Invalid NJT static archive');
		return parse(strFromU8(matches[0][1]), { columns: true, bom: true, skip_empty_lines: true });
	};
	const routes = new Set(rows('routes.txt').filter(r => r.route_type === '0' && Object.hasOwn(ROUTES, r.route_id)).map(r => r.route_id));
	if (!routes.size) throw new NjtError('NJT static archive has no light rail identities');
	const trips = new Map<string, StaticTrip>();
	for (const row of rows('trips.txt')) {
		if (!routes.has(row.route_id)) continue;
		if (!text(row.trip_id) || trips.has(row.trip_id)) throw new NjtError('Invalid NJT static trip identity');
		trips.set(row.trip_id, { id: row.trip_id, routeId: row.route_id, route: ROUTES[row.route_id],
			destination: text(row.trip_headsign) ? row.trip_headsign : 'Destination unavailable',
			direction: direction(row.route_id, row.direction_id, row.trip_headsign || '') });
	}
	const stations = new Map(njtCatalog.flatMap(s => s.parts.map(p => [p.stationId, s] as const)));
	const stops = new Map<string, StaticStop>();
	for (const row of rows('stops.txt')) {
		if (!text(row.stop_id)) throw new NjtError('Invalid NJT static stop identity');
		const idMatch = stations.get(row.stop_id), codeMatch = stations.get(row.stop_code);
		if (idMatch && codeMatch && idMatch.id !== codeMatch.id) continue;
		const station = idMatch || codeMatch;
		if (!station) continue; // No names, coordinate proximity, or public rail IDs.
		const route = station.routes[0];
		if (!Object.entries(ROUTES).some(([id, product]) => product === route && routes.has(id))) continue;
		if (stops.has(row.stop_id)) throw new NjtError('Invalid NJT static stop identity');
		stops.set(row.stop_id, { id: row.stop_id, ...(text(row.stop_code) ? { code: row.stop_code } : {}),
			name: text(row.stop_name) ? row.stop_name : station.name, stationId: station.id, route });
	}
	if (!trips.size || !stops.size) throw new NjtError('Incomplete NJT light rail identity');
	return { trips, stops, routes };
}

function restoredState(value: any, expected: SourceState, now: number): SourceState {
	if (!record(value) || value.id !== expected.id || !epoch(value.timestamp) || !epoch(value.fetchedAt)
		|| value.timestamp > value.fetchedAt + 60 || value.fetchedAt > now + 60 || (value.error != null && typeof value.error !== 'string')) {
		throw new NjtError('Invalid NJT cached source');
	}
	return { ...expected, timestamp: value.timestamp, fetchedAt: value.fetchedAt, error: value.error ? 'Cached NJT source unavailable' : null };
}

/** Official production G2 light rail identity, predictions and actual observations.
 * Scheduling is owned by TransitService; this class starts no internal timers.
 */
export class NjtLiveService {
	readonly enabled: boolean;
	private readonly fetcher: typeof fetch;
	private identity?: StaticIdentity;
	private staticState = state(`${PROVIDER}-static`, 86400);
	private predictionState = state(PREDICTIONS);
	private positionState = state(POSITIONS);
	private trains = new Map<string, { train: Train; raw: unknown }>();
	private positions = new Map<string, VehiclePosition>();
	private predictionHeader: unknown = null;
	private token?: { value: string; expiresAt: number };
	private authNotBefore = 0;
	private authenticating?: Promise<string>;
	private pending = new Map<string, Promise<void>>();
	private cacheErrors = new Map<string, string>();

	constructor(private readonly options: Options) {
		this.enabled = !!options.credentials?.username && !!options.credentials?.password;
		this.fetcher = options.fetcher ?? fetch;
	}

	private changed() { this.options.onUpdate?.(); }
	private get cacheError() { return this.cacheErrors.size ? [...this.cacheErrors.values()].join('; ') : null; }
	private single(name: string, work: () => Promise<void>): Promise<void> {
		const existing = this.pending.get(name);
		if (existing) return existing;
		const result = work().finally(() => { this.pending.delete(name); });
		this.pending.set(name, result);
		return result;
	}
	private async post(method: string, fields: Record<string, string>): Promise<Response> {
		const body = new FormData();
		for (const [key, value] of Object.entries(fields)) body.set(key, value);
		try {
			const response = await this.fetcher(BASE + method, { method: 'POST', body,
				redirect: 'error', signal: AbortSignal.timeout(method === 'getGTFS' ? 60_000 : 15_000) });
			if (!response.ok) throw new NjtError(`NJT request failed (HTTP ${response.status})`, response.status);
			return response;
		} catch (error) {
			if (error instanceof NjtError) throw error;
			throw new NjtError('NJT request failed');
		}
	}
	private authenticate(): Promise<string> {
		const now = nowSeconds();
		if (this.token && this.token.expiresAt > now) return Promise.resolve(this.token.value);
		if (this.authenticating) return this.authenticating;
		if (now < this.authNotBefore) return Promise.reject(new NjtError('NJT authentication cooldown'));
		this.authNotBefore = now + AUTH_COOLDOWN; // At most eight mint attempts/day per process.
		this.authenticating = (async () => {
			const response = await this.post('authenticateUser', this.options.credentials!);
			let auth: any;
			try { auth = await response.json(); } catch { throw new NjtError('Invalid NJT authentication response'); }
			if (auth?.Authenticated !== 'True' || !text(auth.UserToken) || !auth.UserToken.trim()) throw new NjtError('NJT authentication failed');
			this.token = { value: auth.UserToken, expiresAt: now + TOKEN_LIFETIME };
			return auth.UserToken as string;
		})().finally(() => { this.authenticating = undefined; });
		return this.authenticating;
	}
	private async request(method: string): Promise<Uint8Array> {
		let token = await this.authenticate();
		try {
			let response: Response;
			try { response = await this.post(method, { token }); }
			catch (error) {
				if (!(error instanceof NjtError) || ![401, 403].includes(error.status ?? 0)) throw error;
				// Do not invalidate a replacement minted by another concurrent request.
				if (this.token?.value === token) this.token = undefined;
				token = await this.authenticate();
				response = await this.post(method, { token }); // One retry, never recursive.
			}
			return new Uint8Array(await response.arrayBuffer());
		} catch (error) {
			if (error instanceof NjtError) throw error;
			throw new NjtError('NJT response could not be read');
		}
	}
	private feed(bytes: Uint8Array, fetchedAt: number): any {
		let raw: any;
		try { raw = decode(bytes); } catch { throw new NjtError('Invalid NJT realtime response'); }
		if (!epoch(raw.header?.timestamp) || raw.header.timestamp > fetchedAt + 60 || !Array.isArray(raw.entity ?? [])
			|| raw.header.incrementality === 'DIFFERENTIAL') throw new NjtError('Invalid NJT realtime source timestamp or dataset');
		return raw;
	}
	private stop(id: unknown, route: string): StaticStop | undefined {
		if (!text(id)) return;
		const exact = this.identity?.stops.get(id);
		if (exact?.route === route) return exact;
		const codes = [...(this.identity?.stops.values() ?? [])].filter(s => s.code === id && s.route === route);
		// A product stop_code can name multiple platforms only if they identify the same station.
		if (codes.length && codes.every(s => s.stationId === codes[0].stationId)) return codes[0];
	}

	refreshStatic(): Promise<void> {
		if (!this.enabled) return Promise.resolve();
		return this.single('static', async () => {
			try {
				this.identity = parseStatic(await this.request('getGTFS'));
				const fetchedAt = nowSeconds();
				this.staticState = { ...this.staticState, timestamp: fetchedAt, fetchedAt, error: null };
				await this.save('static', { state: this.staticState, routes: [...this.identity.routes],
					trips: [...this.identity.trips.values()], stops: [...this.identity.stops.values()] });
			} catch (error) {
				this.staticState.error = safeError(error);
				this.changed();
				throw new NjtError(this.staticState.error);
			}
			this.changed();
		});
	}

	refreshPredictions(): Promise<void> {
		if (!this.enabled) return Promise.resolve();
		return this.single('predictions', async () => {
			try {
				if (!this.identity) throw new NjtError('NJT static identity unavailable');
				const bytes = await this.request('getTripUpdates'), fetchedAt = nowSeconds(), raw = this.feed(bytes, fetchedAt);
				if (this.predictionState.timestamp != null && raw.header.timestamp < this.predictionState.timestamp) throw new NjtError('NJT prediction source timestamp regressed');
				const trains = new Map<string, { train: Train; raw: unknown }>();
				for (const entity of raw.entity ?? []) {
					const update = entity.trip_update, trip = update?.trip, known = this.identity.trips.get(trip?.trip_id);
					if (!known || entity.is_deleted || ['CANCELED', 'DELETED'].includes(trip.schedule_relationship)
						|| (trip.route_id && trip.route_id !== known.routeId)) continue;
					const timestamp = update.timestamp ?? raw.header.timestamp;
					if (!epoch(timestamp) || timestamp > fetchedAt + 60) throw new NjtError('Invalid NJT prediction timestamp');
					const previous = trains.get(keyFor(trip)) ?? this.trains.get(keyFor(trip));
					if (previous && timestamp < previous.train.timestamp) throw new NjtError('NJT trip prediction timestamp regressed');
					const predictions: StopPrediction[] = [];
					for (const stop of update.stop_time_update ?? []) {
						if (['NO_DATA', 'SKIPPED'].includes(stop.schedule_relationship)) continue;
						const mapped = this.stop(stop.stop_id, known.route);
						if (!mapped) continue;
						const arrival = epoch(stop.arrival?.time) ? stop.arrival.time : null;
						const departure = epoch(stop.departure?.time) ? stop.departure.time : null;
						if ((departure ?? arrival ?? 0) <= fetchedAt) continue;
						const sequence = Number.isSafeInteger(stop.stop_sequence) && stop.stop_sequence > 0 ? stop.stop_sequence : undefined;
						predictions.push({ id: stop.stop_id, stationId: mapped.stationId, name: mapped.name,
							arrival, departure, ...(sequence != null ? { sequence } : {}),
							...(stop.schedule_relationship ? { relationship: stop.schedule_relationship } : {}) });
					}
					if (!predictions.length) continue;
					predictions.sort((a, b) => (a.sequence ?? Infinity) - (b.sequence ?? Infinity) || (a.departure ?? a.arrival!) - (b.departure ?? b.arrival!));
					const train: Train = { key: keyFor(trip), feed: PREDICTIONS, tripId: known.id, route: known.route,
						destination: known.destination, direction: known.direction, timestamp, staleAfter: STALE_AFTER,
						stops: predictions, alerts: [], ...(serviceDate(trip.start_date) ? { serviceDate: trip.start_date } : {}),
						...(startTime(trip.start_time) ? { startTime: trip.start_time } : {}) };
					trains.set(train.key, { train, raw: update });
				}
				this.trains = trains;
				this.predictionHeader = raw.header;
				this.predictionState = { ...this.predictionState, timestamp: raw.header.timestamp, fetchedAt, error: null };
				await this.save('predictions', { state: this.predictionState, trains: [...trains.values()].map(t => t.train) });
			} catch (error) {
				this.predictionState.error = safeError(error);
				this.changed();
				throw new NjtError(this.predictionState.error);
			}
			this.changed();
		});
	}

	private position(value: any, fetchedAt: number): VehiclePosition | undefined {
		if (!this.identity || !record(value)) return;
		const trip = value.trip ?? {}, known = this.identity.trips.get(trip.trip_id);
		const routeId = known?.routeId ?? trip.route_id, route = ROUTES[routeId];
		if (!route || !this.identity.routes.has(routeId) || (known && trip.route_id && trip.route_id !== known.routeId)) return;
		const vehicleId = value.vehicle?.id;
		if (!text(vehicleId) || !epoch(value.timestamp) || value.timestamp > fetchedAt + 60) return;
		const lat = value.position?.latitude, lon = value.position?.longitude;
		if (typeof lat !== 'number' || typeof lon !== 'number' || !Number.isFinite(lat) || !Number.isFinite(lon)
			|| lat < -90 || lat > 90 || lon < -180 || lon > 180 || (lat === 0 && lon === 0)) return;
		const stop = this.stop(value.stop_id, route);
		return { id: vehicleKey(route, vehicleId), provider: PROVIDER, vehicleId, route, lat, lon,
			timestamp: value.timestamp, fetchedAt, ...(text(trip.trip_id) ? { tripId: trip.trip_id } : {}),
			...(serviceDate(trip.start_date) ? { serviceDate: trip.start_date } : {}),
			...(startTime(trip.start_time) ? { startTime: trip.start_time } : {}),
			...(stop ? { stopId: stop.id, stopName: stop.name } : {}),
			...(['STOPPED_AT', 'IN_TRANSIT_TO', 'INCOMING_AT'].includes(value.current_status) ? { status: value.current_status } : {}) };
	}
	refreshPositions(): Promise<void> {
		if (!this.enabled) return Promise.resolve();
		return this.single('positions', async () => {
			try {
				if (!this.identity) throw new NjtError('NJT static identity unavailable');
				const bytes = await this.request('getVehiclePositions'), fetchedAt = nowSeconds(), raw = this.feed(bytes, fetchedAt);
				if (this.positionState.timestamp != null && raw.header.timestamp < this.positionState.timestamp) throw new NjtError('NJT position source timestamp regressed');
				for (const entity of raw.entity ?? []) {
					if (entity.is_deleted) continue;
					const position = this.position(entity.vehicle, fetchedAt);
					if (!position) continue;
					const previous = this.positions.get(position.id);
					// Repeated observations must preserve source age, fetchedAt and trip identity.
					if (!previous || position.timestamp > previous.timestamp) this.positions.set(position.id, position);
				}
				this.positionState = { ...this.positionState, timestamp: raw.header.timestamp, fetchedAt, error: null };
				await this.save('positions', { state: this.positionState, positions: [...this.positions.values()] });
			} catch (error) {
				this.positionState.error = safeError(error);
				this.changed();
				throw new NjtError(this.positionState.error);
			}
			this.changed();
		});
	}

	private currentPositions(now: number) {
		return [...this.positions.values()].filter(p => p.timestamp <= now + 60 && now - p.timestamp <= POSITION_MAX_AGE)
			.sort((a, b) => a.id.localeCompare(b.id));
	}
	private positioned(train: Train, now: number): Train {
		const result = structuredClone(train);
		if (!train.tripId || !train.serviceDate || !train.startTime) return result;
		const matches = this.currentPositions(now).filter(p => p.route === train.route && p.tripId === train.tripId
			&& p.serviceDate === train.serviceDate && p.startTime === train.startTime);
		if (matches.length !== 1) return result;
		result.vehiclePosition = { ...matches[0] };
		if (matches[0].stopId) result.position = { stopId: matches[0].stopId, name: matches[0].stopName!,
			status: matches[0].status, timestamp: matches[0].timestamp };
		return result;
	}
	private njtState(): NjtState {
		return { configured: this.enabled, predictions: { ...this.predictionState }, positions: { ...this.positionState }, cacheError: this.cacheError };
	}
	board(station: Station, now = nowSeconds()): Board {
		const departures: Departure[] = [];
		if (this.enabled) for (const { train: original } of this.trains.values()) {
			const train = this.positioned(original, now);
			for (const [index, stop] of train.stops.entries()) {
				const part = station.parts.find(p => p.id === stop.stationId);
				const time = stop.departure ?? stop.arrival;
				if (!part || time == null || time <= now) continue;
				const actual = train.position && train.stops.find(s => s.id === train.position!.stopId);
				const stopsAway = actual?.sequence != null && stop.sequence != null && stop.sequence >= actual.sequence ? stop.sequence - actual.sequence : null;
				const position = train.vehiclePosition;
				const location = position?.stopName ? `${position.status === 'STOPPED_AT' ? 'At' : position.status === 'INCOMING_AT' ? 'Approaching' : position.status === 'IN_TRANSIT_TO' ? 'In transit to' : 'Reported stop'} ${position.stopName}`
					: position ? 'Reported GPS position' : 'Position unavailable';
				departures.push({ key: `${train.key}|${stop.id}|${stop.sequence ?? index}`, tripKey: train.key,
					route: train.route, destination: train.destination, direction: train.direction, stopId: stop.id, partId: part.id,
					area: `${part.line} · To ${train.destination}`, time, arrival: stop.arrival, departure: stop.departure,
					pattern: NJT_LINES[train.route].name, patternSource: 'static', location,
					...(position ? { vehiclePosition: { ...position }, locationTimestamp: position.timestamp } : {}),
					stopsAway, feed: train.feed, timestamp: train.timestamp, staleAfter: STALE_AFTER, alerts: [],
					onward: train.stops.slice(index + 1).filter(s => s.stationId).map(s => ({ stationId: s.stationId!, stopId: s.id, name: s.name, time: s.arrival ?? s.departure })) });
			}
		}
		departures.sort((a, b) => a.time! - b.time! || a.key.localeCompare(b.key));
		return { station, generatedAt: now, departures, sources: [{ ...this.predictionState }, { ...this.positionState }], alerts: [],
			njt: this.njtState(), vehiclePositions: this.enabled ? this.currentPositions(now).filter(p => station.routes.includes(p.route)).map(p => ({ ...p })) : [] };
	}
	details(): Map<string, Detail> {
		if (!this.enabled) return new Map();
		return new Map([...this.trains].map(([key, value]) => [key, { train: this.positioned(value.train, nowSeconds()),
			raw: structuredClone(value.raw), source: { state: { ...this.predictionState }, header: structuredClone(this.predictionHeader) } }]));
	}
	health(now = nowSeconds()) {
		const age = (s: SourceState) => s.timestamp == null ? null : Math.max(0, now - s.timestamp);
		return { ...this.njtState(), static: { ...this.staticState },
			ages: { static: age(this.staticState), predictions: age(this.predictionState), positions: age(this.positionState) },
			counts: { trips: this.identity?.trips.size ?? 0, trains: this.trains.size, positions: this.positions.size, currentPositions: this.currentPositions(now).length } };
	}

	private async save(kind: string, value: object): Promise<void> {
		const filename = path.join(this.options.cacheDir, `njt-live-${kind}.json`);
		const temporary = `${filename}.${randomUUID()}.tmp`;
		try {
			await mkdir(this.options.cacheDir, { recursive: true });
			const file = await open(temporary, 'wx', 0o600);
			try { await file.writeFile(JSON.stringify({ version: 1, ...value })); await file.sync(); }
			finally { await file.close(); }
			await rename(temporary, filename);
			this.cacheErrors.delete(kind);
		} catch {
			this.cacheErrors.set(kind, `NJT ${kind} cache could not be saved`);
		} finally { await rm(temporary, { force: true }).catch(() => {}); }
	}
	private async load(kind: string): Promise<any | undefined> {
		try {
			const value = JSON.parse(await readFile(path.join(this.options.cacheDir, `njt-live-${kind}.json`), 'utf8'));
			if (!record(value) || value.version !== 1) throw new NjtError('Invalid NJT cache');
			return value;
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== 'ENOENT') this.cacheErrors.set(kind, `NJT ${kind} cache could not be restored`);
		}
	}
	restore(): Promise<void> {
		return this.single('restore', async () => {
			const now = nowSeconds(), identity = await this.load('static');
			if (identity) try {
				const source = restoredState(identity.state, this.staticState, now);
				if (!Array.isArray(identity.routes) || !identity.routes.length || !identity.routes.every((r: any) => text(r) && Object.hasOwn(ROUTES, r))
					|| !Array.isArray(identity.trips) || !identity.trips.length || !Array.isArray(identity.stops) || !identity.stops.length) throw new NjtError('Invalid NJT static cache');
				const trips = new Map<string, StaticTrip>(), stops = new Map<string, StaticStop>();
				for (const trip of identity.trips) {
					if (!record(trip) || !text(trip.id) || trips.has(trip.id) || !identity.routes.includes(trip.routeId)
						|| ROUTES[trip.routeId] !== trip.route || !text(trip.destination) || !['NORTH', 'SOUTH', 'UNKNOWN'].includes(trip.direction)) throw new NjtError('Invalid NJT trip cache');
					trips.set(trip.id, { id: trip.id, routeId: trip.routeId, route: trip.route, destination: trip.destination,
						direction: trip.routeId === 'NLR' ? direction('NLR', '', trip.destination) : trip.direction });
				}
				for (const stop of identity.stops) {
					const station = njtCatalog.find(s => s.id === stop.stationId && s.routes.includes(stop.route));
					if (!record(stop) || !text(stop.id) || stops.has(stop.id) || !text(stop.name) || !station
						|| !station.parts.some(p => p.stationId === stop.id || p.stationId === stop.code)) throw new NjtError('Invalid NJT stop cache');
					stops.set(stop.id, { id: stop.id, ...(text(stop.code) ? { code: stop.code } : {}), name: stop.name, stationId: stop.stationId, route: stop.route });
				}
				this.identity = { trips, stops, routes: new Set(identity.routes) };
				this.staticState = source;
				this.cacheErrors.delete('static');
			} catch { this.cacheErrors.set('static', 'NJT static cache could not be restored'); }
			const predictions = await this.load('predictions');
			if (predictions) try {
				if (!this.identity || !Array.isArray(predictions.trains)) throw new NjtError('Invalid NJT prediction cache');
				const source = restoredState(predictions.state, this.predictionState, now), trains = new Map<string, { train: Train; raw: unknown }>();
				for (const value of predictions.trains) {
					const known = this.identity.trips.get(value?.tripId);
					if (!known || !record(value) || value.route !== known.route || !epoch(value.timestamp) || value.timestamp > source.fetchedAt! + 60
						|| (value.serviceDate != null && !serviceDate(value.serviceDate)) || (value.startTime != null && !startTime(value.startTime)) || !Array.isArray(value.stops)) throw new NjtError('Invalid NJT prediction cache');
					const stops = value.stops.map((s: any): StopPrediction => {
						const mapped = this.stop(s?.id, known.route);
						if (!mapped || !record(s) || ![s.arrival, s.departure].every(time => time === null || epoch(time))
							|| (s.arrival === null && s.departure === null) || (s.relationship != null && !['SCHEDULED', 'UNSCHEDULED'].includes(s.relationship))
							|| (s.sequence != null && (!Number.isSafeInteger(s.sequence) || s.sequence <= 0))) throw new NjtError('Invalid NJT stop prediction cache');
						return { id: s.id, stationId: mapped.stationId, name: mapped.name, arrival: s.arrival, departure: s.departure,
							...(s.sequence != null ? { sequence: s.sequence } : {}), ...(s.relationship ? { relationship: s.relationship } : {}) };
					});
					const train: Train = { key: keyFor({ trip_id: known.id, start_date: value.serviceDate, start_time: value.startTime }),
						feed: PREDICTIONS, tripId: known.id, route: known.route, destination: known.destination, direction: known.direction,
						timestamp: value.timestamp, staleAfter: STALE_AFTER, stops, alerts: [],
						...(value.serviceDate ? { serviceDate: value.serviceDate } : {}), ...(value.startTime ? { startTime: value.startTime } : {}) };
					if (trains.has(train.key)) throw new NjtError('Duplicate NJT cached trip');
					trains.set(train.key, { train, raw: null });
				}
				this.trains = trains; this.predictionState = source; this.predictionHeader = { timestamp: source.timestamp };
				this.cacheErrors.delete('predictions');
			} catch { this.cacheErrors.set('predictions', 'NJT predictions cache could not be restored'); }
			const positions = await this.load('positions');
			if (positions) try {
				if (!this.identity || !Array.isArray(positions.positions)) throw new NjtError('Invalid NJT position cache');
				const source = restoredState(positions.state, this.positionState, now), latest = new Map<string, VehiclePosition>();
				for (const value of positions.positions) {
					if (!record(value) || value.provider !== PROVIDER || !epoch(value.fetchedAt) || value.fetchedAt > now + 60
						|| (value.serviceDate != null && !serviceDate(value.serviceDate)) || (value.startTime != null && !startTime(value.startTime))) throw new NjtError('Invalid NJT position cache');
					const routeId = Object.entries(ROUTES).find(([, route]) => route === value.route)?.[0];
					const position = this.position({ trip: { trip_id: value.tripId, start_date: value.serviceDate, start_time: value.startTime, route_id: routeId },
						vehicle: { id: value.vehicleId }, position: { latitude: value.lat, longitude: value.lon }, timestamp: value.timestamp,
						stop_id: value.stopId, current_status: value.status }, value.fetchedAt);
					if (!position || position.id !== value.id) throw new NjtError('Invalid NJT position cache');
					const previous = latest.get(position.id);
					if (!previous || position.timestamp > previous.timestamp) latest.set(position.id, position);
				}
				this.positions = latest; this.positionState = source;
				this.cacheErrors.delete('positions');
			} catch { this.cacheErrors.set('positions', 'NJT positions cache could not be restored'); }
			this.changed();
		});
	}
}
