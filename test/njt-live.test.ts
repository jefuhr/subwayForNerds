import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import protobuf from 'protobufjs';
import { zipSync, strToU8 } from 'fflate';
import { NjtLiveService } from '../server/njt-live';
import { njtCatalog } from '../server/njt';
import { decode } from '../server/decode';

const now = 1_791_777_440;
const credentials = { username: 'username-secret', password: 'password-secret' };
const root = new protobuf.Root().loadSync(new URL('../server/proto/gtfs-realtime.proto', import.meta.url).pathname, { keepCase: true });
const feedType = root.lookupType('transit_realtime.FeedMessage');
const encode = (raw: any) => feedType.encode(feedType.fromObject(raw)).finish();
const feed = (entity: any[] = [], timestamp = now) => ({ header: { gtfs_realtime_version: '2.0', timestamp }, entity });
const descriptor = { trip_id: 'n0', start_date: '20261011', start_time: '23:00:00' };
const update = (overrides: any = {}) => ({ id: 'update', trip_update: {
	trip: descriptor, timestamp: now, stop_time_update: [
		{ stop_id: 'GROVE', stop_sequence: 1, arrival: { time: now + 120 } },
		{ stop_id: 'PENN', stop_sequence: 2, departure: { time: now + 300 } },
	], ...overrides,
} });
const vehicle = (overrides: any = {}) => ({ id: 'vehicle-entity', vehicle: {
	trip: descriptor, vehicle: { id: 'train-one' }, timestamp: now,
	position: { latitude: 40.735, longitude: -74.164 }, stop_id: 'GROVE', current_status: 'IN_TRANSIT_TO',
	...overrides,
} });
const station = (code = '30771') => njtCatalog.find(s => s.id === `njt-lr-${code}`)!;
const staticZip = () => zipSync(Object.fromEntries(Object.entries({
	'routes.txt': 'route_id,route_type\nNLR,0\nHBLR,0\nRvLN,0\n100,3\n1,2\n',
	'trips.txt': 'route_id,trip_id,trip_headsign,direction_id,shape_id\nNLR,n0,Newark Penn Station,0,n0\nNLR,n1,Grove Street,1,n1\nNLR,broad,NLR BROAD ST STATION,1,b\nNLR,via,NLR BROAD ST VIA PENN,1,v\nHBLR,h0,8th Street,0,h0\nHBLR,h1,Hoboken,1,h1\nRvLN,r0,Trenton,1,r0\n100,bus,Newark Penn Station,0,b\n1,rail,Newark Penn Station,0,p\n',
	'stops.txt': 'stop_id,stop_code,stop_name\nGROVE,30539,Grove Street\nPENN,30771,Newark Penn Station\nNAME_ONLY,,Newark Penn Station\nHOBOKEN,30829,Hoboken\nRIVER,30855,Trenton\n',
	'stop_times.txt': 'trip_id,stop_id,stop_sequence,arrival_time,departure_time\nn0,GROVE,1,01:00:00,01:00:00\nn0,PENN,2,01:10:00,01:10:00\nn0,NAME_ONLY,3,01:20:00,01:20:00\nn1,PENN,1,01:00:00,01:00:00\nn1,GROVE,2,01:10:00,01:10:00\nh0,HOBOKEN,1,01:00:00,01:00:00\nr0,RIVER,1,01:00:00,01:00:00\nbus,PENN,1,01:00:00,01:00:00\nrail,PENN,1,01:00:00,01:00:00\n',
}).map(([name, text]) => [name, strToU8(text)])));

async function fixture(t: TestContext, initial: any[] = [update()]) {
	t.mock.method(Date, 'now', () => now * 1000);
	const cacheDir = await mkdtemp(path.join(tmpdir(), 'njt-live-'));
	t.after(() => rm(cacheDir, { recursive: true, force: true }));
	const requests: { url: string; init: RequestInit }[] = [];
	const responses: Record<string, Uint8Array | Error | number | object> = {
		getGTFS: staticZip(), getTripUpdates: encode(feed(initial)), getVehiclePositions: encode(feed([vehicle()])),
	};
	const fetcher: typeof fetch = async (url, init) => {
		requests.push({ url: String(url), init: init! });
		const method = String(url).split('/').at(-1)!;
		if (method === 'authenticateUser') return Response.json(responses.auth ?? { Authenticated: 'True', UserToken: 'token-secret' });
		const response = responses[method];
		if (response instanceof Error) throw response;
		if (typeof response === 'number') return new Response('token-secret upstream body', { status: response });
		return new Response(response as Uint8Array<ArrayBuffer>);
	};
	const service = new NjtLiveService({ cacheDir, credentials, fetcher });
	await service.refreshStatic();
	return { service, responses, requests, cacheDir, fetcher };
}

test('unconfigured service makes no network requests and preserves the external catalog', async t => {
	const { cacheDir } = await fixture(t);
	const service = new NjtLiveService({ cacheDir, fetcher: async () => { throw Error('must not fetch'); } });
	await service.restore();
	await Promise.all([service.refreshStatic(), service.refreshPredictions(), service.refreshPositions()]);
	assert.equal(service.enabled, false);
	assert.equal(service.board(station(), now).njt?.configured, false);
	assert.equal(service.board(station(), now).station.departureMode, 'external');
	assert.deepEqual(service.board(station(), now).departures, []);
});

test('only explicit future live timestamps for exact static light rail trips and stops become predictions', async t => {
	const { service, responses } = await fixture(t);
	responses.getTripUpdates = encode(feed([
		update(), update({ trip: { ...descriptor, trip_id: 'bus' } }), update({ trip: { ...descriptor, trip_id: 'rail' } }),
		update({ trip: { ...descriptor, trip_id: 'unknown', route_id: 'NLR' } }),
		update({ trip: { ...descriptor, trip_id: 'n1' }, stop_time_update: [{ stop_id: 'PENN', departure: { time: now + 400 } }] }),
		update({ trip: { ...descriptor, trip_id: 'h0' }, stop_time_update: [{ stop_id: 'HOBOKEN', arrival: { time: now + 400 } }] }),
		update({ trip: { ...descriptor, trip_id: 'r0' }, stop_time_update: [{ stop_id: 'RIVER', arrival: { time: now + 400 } }] }),
	]));
	await service.refreshPredictions();
	const board = service.board(station(), now);
	assert.equal(board.njt?.configured, true);
	assert.equal(board.departures.length, 2);
	assert.deepEqual(board.departures.map(d => d.direction), ['SOUTH', 'NORTH']);
	assert.equal(board.departures[0].route, 'NJT-NLR');
	assert.equal(board.departures[0].area.includes('Newark Penn Station'), true);
	assert.equal(board.departures[0].patternSource, 'static');
	assert.equal(board.departures[0].stopsAway, null);
	assert.equal(board.departures[0].staleAfter, 60);
	assert.equal(board.departures[0].time, now + 300);
	assert.equal(service.board(station('30829'), now).departures[0].route, 'NJT-HBLR');
	assert.equal(service.board(station('30855'), now).departures[0].route, 'NJT-RIVER');
	assert.equal(service.details().size, 4);
	const train = [...service.details().values()][0].train;
	assert.equal(train.staleAfter, 60);
	assert.ok(train.stops.every(s => s.name !== 'NAME_ONLY'));
	assert.match(train.key, /20261011.*n0.*23:00:00/);
});

test('NO_DATA, SKIPPED, canceled, deleted, delay-only and scheduled-only updates never fabricate predictions', async t => {
	const { service, responses } = await fixture(t);
	for (const relationship of ['NO_DATA', 'SKIPPED']) {
		responses.getTripUpdates = encode(feed([update({ stop_time_update: [{ stop_id: 'PENN', schedule_relationship: relationship, departure: { time: now + 100 } }] })]));
		await service.refreshPredictions();
		assert.equal(service.board(station(), now).departures.length, 0);
	}
	for (const relationship of ['CANCELED', 'DELETED']) {
		responses.getTripUpdates = encode(feed([update({ trip: { ...descriptor, schedule_relationship: relationship } })]));
		await service.refreshPredictions();
		assert.equal(service.details().size, 0);
	}
	responses.getTripUpdates = encode(feed([update({ stop_time_update: [
		{ stop_id: 'PENN', departure: { delay: 30, scheduled_time: now + 500 } },
		{ stop_id: 'NAME_ONLY', departure: { time: now + 500 } },
		{ stop_id: 'PENN', departure: { time: now - 1 } },
	] })]));
	await service.refreshPredictions();
	assert.equal(service.board(station(), now).departures.length, 0);
	assert.equal(service.board(station(), now).njt?.predictions.error, null);
});

test('trip identity includes date and start time and is independent of realtime entity IDs', async t => {
	const { service, responses } = await fixture(t);
	responses.getTripUpdates = encode(feed([update(), { ...update({ trip: { ...descriptor, start_time: '24:00:00' } }), id: 'other' }]));
	await service.refreshPredictions();
	const keys = [...service.details().keys()];
	assert.equal(keys.length, 2);
	assert.notEqual(keys[0], keys[1]);
	responses.getTripUpdates = encode(feed([{ ...update(), id: 'renumbered' }]));
	await service.refreshPredictions();
	assert.equal([...service.details().keys()][0], keys[0]);
});

test('HBLR direction_id 0 maps south and 1 maps north while board areas describe destinations', async t => {
	const { service, responses } = await fixture(t);
	responses.getTripUpdates = encode(feed([
		update({ trip: { ...descriptor, trip_id: 'h0' }, stop_time_update: [{ stop_id: 'HOBOKEN', departure: { time: now + 200 } }] }),
		update({ trip: { ...descriptor, trip_id: 'h1' }, stop_time_update: [{ stop_id: 'HOBOKEN', departure: { time: now + 300 } }] }),
	]));
	await service.refreshPredictions();
	const rows = service.board(station('30829'), now).departures;
	assert.deepEqual(rows.map(row => row.direction), ['SOUTH', 'NORTH']);
	assert.match(rows[0].area, /To 8th Street/);
	assert.match(rows[1].area, /To Hoboken/);
});

test('prediction and position failures are independent and source timestamp controls freshness', async t => {
	const { service, responses } = await fixture(t);
	responses.getTripUpdates = encode(feed([update({ timestamp: now - 90 })]));
	await service.refreshPredictions();
	assert.equal(service.board(station(), now).departures[0].timestamp, now - 90);
	responses.getTripUpdates = new Error('username-secret password-secret token-secret');
	await assert.rejects(service.refreshPredictions(), /NJT/);
	await service.refreshPositions();
	let board = service.board(station(), now);
	assert.ok(board.njt?.predictions.error);
	assert.equal(board.njt?.positions.error, null);
	assert.equal(board.vehiclePositions?.length, 1);
	assert.equal(board.departures[0].timestamp, now - 90);
	assert.doesNotMatch(JSON.stringify(service.health(now)), /username-secret|password-secret|token-secret/);
	responses.getTripUpdates = encode(feed([update()]));
	responses.getVehiclePositions = 503;
	await service.refreshPredictions();
	await assert.rejects(service.refreshPositions(), /NJT/);
	board = service.board(station(), now);
	assert.equal(board.njt?.predictions.error, null);
	assert.ok(board.njt?.positions.error);
	assert.equal(board.departures[0].time, now + 300);
});

test('positions join only complete exact trip/date/start-time identities and use actual stop evidence', async t => {
	const { service, responses } = await fixture(t);
	await service.refreshPredictions();
	await service.refreshPositions();
	let row = service.board(station(), now).departures[0];
	assert.equal(row.vehiclePosition?.vehicleId, 'train-one');
	assert.equal(row.vehiclePosition?.stopName, 'Grove Street');
	assert.equal(row.stopsAway, 1);
	for (const [index, trip] of [
		{ trip_id: 'n0', start_time: descriptor.start_time },
		{ ...descriptor, start_date: '20261010' },
		{ ...descriptor, start_time: '23:01:00' },
		{ ...descriptor, trip_id: 'n1' },
	].entries()) {
		responses.getVehiclePositions = encode(feed([vehicle({ timestamp: now + index + 1, trip })]));
		await service.refreshPositions();
		row = service.board(station(), now).departures[0];
		assert.equal(row.vehiclePosition, undefined);
		assert.equal(row.stopsAway, null);
		responses.getVehiclePositions = encode(feed([]));
	}
	responses.getTripUpdates = encode(feed([update({ trip: { trip_id: 'n0', start_time: descriptor.start_time } })]));
	responses.getVehiclePositions = encode(feed([vehicle({ timestamp: now + 10 })]));
	await service.refreshPredictions();
	await service.refreshPositions();
	assert.equal(service.board(station(), now).departures[0].vehiclePosition, undefined);
});

test('latest-only positions retain timestamp and identity on equal or older observations, reject bad coordinates and expire after 300 seconds', async t => {
	const { service, responses, cacheDir } = await fixture(t, []);
	await service.refreshPositions();
	const original = service.board(station(), now).vehiclePositions![0];
	t.mock.method(Date, 'now', () => (now + 200) * 1000);
	for (const timestamp of [now, now - 1]) {
		responses.getVehiclePositions = encode(feed([vehicle({ timestamp, trip: { ...descriptor, trip_id: 'n1' }, position: { latitude: 41, longitude: -75 } })], now + 200));
		await service.refreshPositions();
		assert.deepEqual(service.board(station(), now + 200).vehiclePositions![0], original);
	}
	for (const position of [{ latitude: 91, longitude: 0 }, { latitude: 40, longitude: 181 }, undefined, {}]) {
		responses.getVehiclePositions = encode(feed([vehicle({ timestamp: now + 100, position })], now + 200));
		await service.refreshPositions();
		assert.deepEqual(service.board(station(), now + 200).vehiclePositions![0], original);
	}
	responses.getVehiclePositions = encode(feed([vehicle({ timestamp: now + 100, position: { latitude: 40.7, longitude: -74.1 } })], now + 200));
	await service.refreshPositions();
	assert.equal(service.board(station(), now + 200).vehiclePositions!.length, 1);
	assert.equal(service.board(station(), now + 401).vehiclePositions!.length, 0);
	const files = await readdir(cacheDir);
	assert.ok(files.every(f => !f.endsWith('.tmp')));
});

test('restart restores normalized static identity, predictions and latest positions without secrets or scheduled times', async t => {
	const { service, fetcher, cacheDir, responses } = await fixture(t);
	await service.refreshPredictions();
	await service.refreshPositions();
	responses.getVehiclePositions = encode(feed([vehicle({ timestamp: now + 1 })], now + 1));
	await service.refreshPositions();
	const files = await readdir(cacheDir);
	assert.ok(files.length > 0);
	const serialized = (await Promise.all(files.map(f => readFile(path.join(cacheDir, f), 'utf8')))).join('\n');
	assert.doesNotMatch(serialized, /username-secret|password-secret|token-secret|arrival_time|departure_time/);
	const restored = new NjtLiveService({ cacheDir, credentials, fetcher });
	await restored.restore();
	assert.equal(restored.board(station(), now).departures[0].time, now + 300);
	assert.equal(restored.board(station(), now).vehiclePositions?.length, 1);
	assert.equal(restored.board(station(), now).vehiclePositions![0].timestamp, now + 1);
	assert.equal(restored.board(station(), now + 302).vehiclePositions?.length, 0);
	responses.getTripUpdates = encode(feed([update({ trip: { ...descriptor, trip_id: 'n1' }, stop_time_update: [{ stop_id: 'PENN', departure: { time: now + 600 } }] })]));
	await restored.refreshPredictions();
	assert.equal(restored.board(station(), now).departures[0].direction, 'NORTH');
});

test('corrupt cache restores gracefully and cannot inject coordinates or unvalidated trip joins', async t => {
	const { cacheDir, fetcher } = await fixture(t);
	const files = await readdir(cacheDir);
	for (const file of files) await writeFile(path.join(cacheDir, file), '{ corrupt');
	const restored = new NjtLiveService({ cacheDir, credentials, fetcher });
	await assert.doesNotReject(restored.restore());
	assert.ok(restored.board(station(), now).njt?.cacheError);
	assert.equal(restored.board(station(), now).departures.length, 0);
	assert.equal(restored.board(station(), now).vehiclePositions?.length, 0);
});

test('auth uses official multipart methods, reuses its token and bounds retries with a cooldown', async t => {
	const { service, requests, responses } = await fixture(t);
	await Promise.all([service.refreshPredictions(), service.refreshPositions()]);
	assert.equal(requests.filter(r => r.url.endsWith('authenticateUser')).length, 1);
	assert.ok(requests.every(r => r.url.startsWith('https://pcsdata.njtransit.com/api/GTFSG2/')));
	assert.ok(requests.every(r => r.init.method === 'POST' && r.init.redirect === 'error' && r.init.signal));
	assert.equal((requests[0].init.body as FormData).get('username'), credentials.username);
	assert.ok(requests.slice(1).every(r => (r.init.body as FormData).get('token') === 'token-secret'));
	responses.getTripUpdates = 401;
	await assert.rejects(service.refreshPredictions(), /NJT/);
	await assert.rejects(service.refreshPredictions(), /NJT/);
	assert.equal(requests.filter(r => r.url.endsWith('authenticateUser')).length, 1);
	t.mock.method(Date, 'now', () => (now + 3 * 3600) * 1000);
	await assert.rejects(service.refreshPredictions(), /NJT/);
	assert.equal(requests.filter(r => r.url.endsWith('authenticateUser')).length, 2);
	await assert.rejects(service.refreshPredictions(), /NJT/);
	assert.equal(requests.filter(r => r.url.endsWith('authenticateUser')).length, 2);
	assert.doesNotMatch(JSON.stringify(service.health(now)), /username-secret|password-secret|token-secret/);
});

test('malformed auth and throwing upstream responses are sanitized and cannot trigger auth storms', async t => {
	const { cacheDir } = await fixture(t);
	let calls = 0;
	const service = new NjtLiveService({ cacheDir, credentials, fetcher: async () => {
		calls++;
		throw Error('username-secret password-secret token-secret');
	} });
	const outcomes = await Promise.allSettled([service.refreshStatic(), service.refreshPredictions(), service.refreshPositions()]);
	assert.ok(outcomes.every(result => result.status === 'rejected'));
	await assert.rejects(service.refreshPredictions(), /NJT/);
	assert.equal(calls, 1);
	assert.doesNotMatch(JSON.stringify(service.health(now)), /username-secret|password-secret|token-secret/);
});

test('invalid static and realtime source timestamps report failures while retaining the last valid snapshots', async t => {
	const { service, responses } = await fixture(t);
	await service.refreshPredictions();
	await service.refreshPositions();
	responses.getGTFS = zipSync({ 'routes.txt': strToU8('route_id,route_type\n1,2\n') });
	await assert.rejects(service.refreshStatic(), /NJT/);
	assert.ok(service.health(now).static.error);
	assert.equal(service.board(station(), now).departures.length, 1);
	for (const timestamp of [0, now * 1000, now + 61, now - 1]) {
		responses.getTripUpdates = encode(feed([], timestamp));
		responses.getVehiclePositions = encode(feed([], timestamp));
		await assert.rejects(service.refreshPredictions(), /NJT/);
		await assert.rejects(service.refreshPositions(), /NJT/);
		const board = service.board(station(), now);
		assert.ok(board.njt?.predictions.error);
		assert.ok(board.njt?.positions.error);
		assert.equal(board.departures[0].time, now + 300);
		assert.equal(board.vehiclePositions?.length, 1);
	}
});

test('well-formed but invalid cached coordinates fail validation independently of restored predictions', async t => {
	const { service, cacheDir, fetcher } = await fixture(t);
	await service.refreshPredictions();
	await service.refreshPositions();
	const filename = path.join(cacheDir, 'njt-live-positions.json');
	const data = JSON.parse(await readFile(filename, 'utf8'));
	data.positions[0].lat = 100;
	await writeFile(filename, JSON.stringify(data));
	const restored = new NjtLiveService({ cacheDir, credentials, fetcher });
	await restored.restore();
	const board = restored.board(station(), now);
	assert.equal(board.departures.length, 1);
	assert.equal(board.vehiclePositions?.length, 0);
	assert.match(board.njt!.cacheError!, /positions/);
});

test('cache restore rejects stop relationships that cannot supply predictions', async t => {
	const { service, cacheDir, fetcher } = await fixture(t);
	await service.refreshPredictions();
	const filename = path.join(cacheDir, 'njt-live-predictions.json');
	const data = JSON.parse(await readFile(filename, 'utf8'));
	data.trains[0].stops[0].relationship = 'NO_DATA';
	await writeFile(filename, JSON.stringify(data));
	const restored = new NjtLiveService({ cacheDir, credentials, fetcher });
	await restored.restore();
	assert.equal(restored.board(station(), now).departures.length, 0);
	assert.match(restored.board(station(), now).njt!.cacheError!, /predictions/);
});

test('equal and older observations after restart cannot reset fetchedAt or change trip identity', async t => {
	const { service, cacheDir, fetcher, responses } = await fixture(t);
	await service.refreshPositions();
	const original = service.board(station(), now).vehiclePositions![0];
	const restored = new NjtLiveService({ cacheDir, credentials, fetcher });
	await restored.restore();
	t.mock.method(Date, 'now', () => (now + 200) * 1000);
	responses.getVehiclePositions = encode(feed([vehicle({ trip: { ...descriptor, start_time: '24:00:00' } })], now + 200));
	await restored.refreshPositions();
	assert.deepEqual(restored.board(station(), now + 200).vehiclePositions![0], original);
	assert.equal(restored.board(station(), now + 301).vehiclePositions?.length, 0);
	assert.equal(JSON.parse(await readFile(path.join(cacheDir, 'njt-live-positions.json'), 'utf8')).positions.length, 1);
});

test('token expiration and concurrent first live polls use one authentication attempt, with one retry on 403', async t => {
	const { cacheDir, requests, fetcher, responses } = await fixture(t);
	const service = new NjtLiveService({ cacheDir, credentials, fetcher });
	await service.restore();
	await Promise.all([service.refreshPredictions(), service.refreshPositions()]);
	assert.equal(requests.filter(r => r.url.endsWith('authenticateUser')).length, 2);
	t.mock.method(Date, 'now', () => (now + 24 * 3600) * 1000);
	responses.getTripUpdates = encode(feed([], now + 24 * 3600));
	await service.refreshPredictions();
	assert.equal(requests.filter(r => r.url.endsWith('authenticateUser')).length, 3);
	t.mock.method(Date, 'now', () => (now + 27 * 3600) * 1000);
	let calls = 0, auth = 0;
	const reauth = new NjtLiveService({ cacheDir, credentials, fetcher: async (url, init) => {
		if (String(url).endsWith('authenticateUser')) {
			auth++;
			return Response.json({ Authenticated: 'True', UserToken: `opaque-${auth}` });
		}
		if ((init!.body as FormData).get('token') === 'opaque-1' && calls++ > 0) return new Response('', { status: 403 });
		return new Response(encode(feed([], now + 30 * 3600)) as Uint8Array<ArrayBuffer>);
	} });
	await reauth.restore();
	await assert.rejects(reauth.refreshPositions(), /NJT/);
	t.mock.method(Date, 'now', () => (now + 30 * 3600) * 1000);
	await reauth.refreshPositions();
	assert.equal(auth, 2);
	assert.equal(reauth.board(station(), now + 30 * 3600).njt?.positions.error, null);
});

test('authentication response must explicitly be True and failed cache writes do not become feed failures', async t => {
	const { cacheDir, fetcher, service } = await fixture(t);
	let calls = 0;
	const rejected = new NjtLiveService({ cacheDir, credentials, fetcher: async () => {
		calls++;
		return Response.json({ Authenticated: 'False', UserToken: 'token-secret', message: 'password-secret' });
	} });
	await rejected.restore();
	const outcomes = await Promise.allSettled([rejected.refreshPredictions(), rejected.refreshPositions()]);
	assert.ok(outcomes.every(result => result.status === 'rejected'));
	assert.equal(calls, 1);
	assert.ok(rejected.board(station(), now).njt?.predictions.error);
	assert.doesNotMatch(JSON.stringify(rejected.health(now)), /password-secret|token-secret/);
	await service.refreshPredictions();
	const blockedPath = path.join(cacheDir, 'not-a-directory');
	await writeFile(blockedPath, 'fixture');
	const noCache = new NjtLiveService({ cacheDir: blockedPath, credentials, fetcher });
	await noCache.refreshStatic();
	await noCache.refreshPredictions();
	await noCache.refreshPositions();
	const board = noCache.board(station(), now);
	assert.equal(board.departures.length, 1);
	assert.equal(board.njt?.predictions.error, null);
	assert.equal(board.njt?.positions.error, null);
	assert.ok(board.njt?.cacheError);
});

test('same-trip entity timestamp regressions cannot replace newer predictions even under a newer feed header', async t => {
	const { service, responses } = await fixture(t);
	await service.refreshPredictions();
	responses.getTripUpdates = encode(feed([update({ timestamp: now - 1,
		stop_time_update: [{ stop_id: 'PENN', departure: { time: now + 900 } }] })], now + 1));
	await assert.rejects(service.refreshPredictions(), /timestamp/);
	assert.equal(service.board(station(), now).departures[0].time, now + 300);
	assert.equal(service.board(station(), now).departures[0].timestamp, now);
	responses.getTripUpdates = encode(feed([update({ timestamp: now * 1000 })], now + 1));
	await assert.rejects(service.refreshPredictions(), /timestamp/);
	assert.equal(service.board(station(), now).departures[0].time, now + 300);
});

test('missing vehicle status describes only a reported stop and never fabricates movement', async t => {
	const { service, responses } = await fixture(t);
	responses.getVehiclePositions = encode(feed([vehicle({ current_status: undefined })]));
	await service.refreshPredictions();
	await service.refreshPositions();
	const row = service.board(station(), now).departures[0];
	assert.equal(row.vehiclePosition?.status, undefined);
	assert.match(row.location, /^Reported stop/);
});

test('sanitized refresh rejection notifies the parent after updating health and then recovers', async t => {
	const { cacheDir, fetcher, responses } = await fixture(t);
	const notices: unknown[] = [];
	const service = new NjtLiveService({ cacheDir, credentials, fetcher, onUpdate: () => notices.push(service.health(now)) });
	await service.restore();
	responses.getTripUpdates = new Error('password-secret token-secret');
	await assert.rejects(service.refreshPredictions(), error => {
		assert.match((error as Error).message, /NJT/);
		assert.doesNotMatch((error as Error).message, /password-secret|token-secret/);
		assert.ok(service.board(station(), now).njt?.predictions.error);
		assert.equal(notices.length, 2);
		return true;
	});
	responses.getTripUpdates = encode(feed([update()]));
	await service.refreshPredictions();
	assert.equal(notices.length, 3);
	assert.equal(service.board(station(), now).njt?.predictions.error, null);
});

test('route-level observations need no arrivals or complete trip identity and GPS alone supplies no stops-away', async t => {
	const { service, responses } = await fixture(t);
	responses.getVehiclePositions = encode(feed([vehicle({ trip: { route_id: 'NLR' }, stop_id: undefined })]));
	await service.refreshPredictions();
	await service.refreshPositions();
	let board = service.board(station(), now);
	assert.equal(board.vehiclePositions?.length, 1);
	assert.equal(board.departures[0].vehiclePosition, undefined);
	assert.equal(board.departures[0].stopsAway, null);
	responses.getVehiclePositions = encode(feed([vehicle({ timestamp: now + 1, stop_id: undefined })]));
	await service.refreshPositions();
	board = service.board(station(), now);
	assert.equal(board.departures[0].vehiclePosition?.vehicleId, 'train-one');
	assert.equal(board.departures[0].stopsAway, null);
	assert.equal(board.departures[0].location, 'Reported GPS position');
});

async function verifyCaptured(t: TestContext, captured: Buffer[]) {
	const { service, responses, cacheDir } = await fixture(t, []);
	[responses.getGTFS, responses.getTripUpdates, responses.getVehiclePositions] = captured;
	await service.refreshStatic();
	await service.refreshPredictions();
	await service.refreshPositions();
	assert.equal(service.details().size, 0);
	assert.equal(service.board(station(), now).departures.length, 0);
	assert.equal(service.board(station(), now).njt?.predictions.error, null);
	const board = service.board(station('30855'), now);
	assert.equal(board.vehiclePositions?.length, 2);
	assert.ok(board.vehiclePositions?.every(p => p.route === 'NJT-RIVER' && p.timestamp === 1_791_777_421));
	assert.equal(board.departures.length, 0);
	const identity = JSON.parse(await readFile(path.join(cacheDir, 'njt-live-static.json'), 'utf8'));
	const nlrTrips = new Set(identity.trips.filter((trip: any) => trip.route === 'NJT-NLR').map((trip: any) => trip.id));
	const capturedUpdates = decode(responses.getTripUpdates as Uint8Array).entity.filter((e: any) => nlrTrips.has(e.trip_update?.trip?.trip_id));
	assert.equal(capturedUpdates.length, 4);
	assert.ok(capturedUpdates.every((e: any) => e.trip_update.stop_time_update.every((s: any) => s.schedule_relationship === 'NO_DATA')));
	const raw = decode(responses.getVehiclePositions as Uint8Array);
	assert.equal(raw.entity.filter((e: any) => e.vehicle?.trip?.route_id === 'RvLN').length, 2);
}

// Sanitized subset of the 2026-10-11 production capture: six exact static trips,
// four NLR NO_DATA updates and two River GPS observations, with no auth data.
test('portable captured light rail subset has no live NLR predictions and two actual River LINE GPS observations', async t => {
	const captured = await Promise.all(['static.zip', 'trip-updates.pb', 'vehicle-positions.pb']
		.map(name => readFile(new URL(`fixtures/njt-g2-light-rail-${name}`, import.meta.url))));
	await verifyCaptured(t, captured);
});

test('full production archive acceptance preserves the same NO_DATA and River GPS results', async t => {
	const artifacts = process.env.NJT_G2_FIXTURE_DIR;
	if (!artifacts) {
		t.skip('Set NJT_G2_FIXTURE_DIR to verify the original full production capture separately.');
		return;
	}
	const captured = await Promise.all(['static.zip', 'getTripUpdates.pb', 'getVehiclePositions.pb']
		.map(name => readFile(path.join(artifacts, `njt-bus-G2-${name}`))));
	await verifyCaptured(t, captured);
});


test('Newark branches use verified destinations and leave via-Penn cardinal directions unspecified', async t => {
	const { service, responses, cacheDir, fetcher } = await fixture(t);
	responses.getTripUpdates = encode(feed(['n0', 'n1', 'broad', 'via'].map((trip_id, index) => update({
		trip: { ...descriptor, trip_id }, stop_time_update: [{ stop_id: 'PENN', departure: { time: now + 100 + index * 100 } }],
	}))));
	await service.refreshPredictions();
	assert.deepEqual(service.board(station(), now).departures.map(d => d.direction), ['SOUTH', 'NORTH', 'NORTH', 'UNKNOWN']);
	const restored = new NjtLiveService({ cacheDir, credentials, fetcher });
	await restored.restore();
	assert.deepEqual(restored.board(station(), now).departures.map(d => d.direction), ['SOUTH', 'NORTH', 'NORTH', 'UNKNOWN']);
});
