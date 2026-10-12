import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { FleetStore } from '../server/fleet-store.mjs';
import { FleetPackService } from '../server/fleet-pack';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';

const now = 1800000000;
const selection = { equipment: ['R160'], yards: ['Jamaica'], historyDays: 7 as const };

function seed(file: string) {
	const store = new FleetStore(file);
	store.importRoster([
		{ car_number: '1', car_class: 'R160', retirement_date: 'In-Service' },
		{ car_number: '2', car_class: 'R211', retirement_date: 'In-Service' },
		{ car_number: '3', car_class: 'R32', retirement_date: 'Retired' },
	], '2026-09-06', 1);
	store.importSupplement({ cars: [], sources: [], yardRules: [
		{ rosterAssignment: true, equipment: ['R160'], routes: [], name: 'Jamaica', url: 'https://example.org/jamaica', date: '2026-09-06', note: 'Test' },
		{ rosterAssignment: true, equipment: ['R211'], routes: [], name: 'Pitkin', url: 'https://example.org/pitkin', date: '2026-09-06', note: 'Test' },
	] });
	for (const [timestamp, location] of [[now - 31 * 86400, 'outside'], [now - 8 * 86400, '30-day'], [now - 7 * 86400, 'boundary'], [now, '7-day']] as const) {
		store.observe([{ namespace: 'nyct', cars: [{ number: '1', type: 'R160' }, { number: '2', type: 'R211' }],
			observation: { timestamp, locationTimestamp: timestamp, location, route: 'E', tripKey: 'test', next: { name: 'Next', stationId: '602', time: timestamp + 90 } } }], timestamp);
	}
	return store;
}

async function ready(packs: FleetPackService, jobId: string) {
	for (let attempt = 0; attempt < 500; attempt++) {
		const state = packs.status(jobId);
		if (state?.state !== 'preparing') return state;
		await new Promise(resolve => setTimeout(resolve, 10));
	}
	throw new Error('Pack preparation timed out');
}

test('v2 pack streams selected records and exact history with linked cars', async () => {
	const dir = await mkdtemp(join(tmpdir(), 'sfn-pack-v2-'));
	const source = join(dir, 'fleet.sqlite'), output = join(dir, 'packs');
	const store = seed(source), packs = new FleetPackService(source, output);
	try {
		await packs.start();
		const first = await packs.request(selection, now);
		const same = await packs.request({ equipment: ['R160', 'R160'], yards: ['Jamaica'], historyDays: 7 }, now);
		assert.equal(first.jobId, same.jobId);
		const state = await ready(packs, first.jobId);
		assert.equal(state?.state, 'ready');
		const manifest = state!.manifest!;
		assert.equal(manifest.schemaVersion, 2);
		assert.equal(manifest.historyStart, now - 7 * 86400);
		assert.deepEqual(manifest.selection, selection);
		assert.equal(manifest.counts.matchedCars, 1);
		assert.equal(manifest.counts.linkedCars, 1);
		assert.equal(manifest.counts.cars, 2);
		assert.equal(manifest.counts.events, 2);
		assert.equal(manifest.counts.eventCars, 4);
		const bytes = await readFile(join(output, `${manifest.id}.jsonl.gz`));
		assert.equal(bytes.length, manifest.archiveByteLength);
		assert.equal(createHash('sha256').update(bytes).digest('hex'), manifest.archiveSha256);
		const text = gunzipSync(bytes).toString('utf8');
		assert.equal(Buffer.byteLength(text), manifest.uncompressedByteLength);
		const lines = text.trimEnd().split('\n').map(line => JSON.parse(line));
		assert.deepEqual(lines[0], ['header', 2, now, now - 7 * 86400, now, selection]);
		assert.deepEqual(lines.filter(line => line[0] === 'car').map(line => line[1]).sort(), ['nyct:R160:1', 'nyct:R211:2']);
		assert.deepEqual(lines.filter(line => line[0] === 'event').map(line => line[3] && JSON.parse(line[3]).location), ['boundary', '7-day']);
		assert.deepEqual(lines.at(-1), ['end', manifest.counts]);
		const full = await packs.request({ equipment: [], yards: [], historyDays: 30 }, now);
		const fullState = await ready(packs, full.jobId);
		assert.equal(fullState?.manifest?.counts.events, 3, JSON.stringify(fullState));
		const unknown = await packs.request({ equipment: [], yards: ['unknown'], historyDays: 7 }, now);
		const unknownState = await ready(packs, unknown.jobId);
		assert.equal(unknownState?.manifest?.counts.cars, 1);
		assert.equal(unknownState?.manifest?.counts.events, 0);
	} finally { await packs.stop(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('v2 pack includes recent events inserted out of timestamp order', async () => {
	const dir = await mkdtemp(join(tmpdir(), 'sfn-pack-backfill-'));
	const source = join(dir, 'fleet.sqlite'), output = join(dir, 'packs');
	const store = new FleetStore(source), packs = new FleetPackService(source, output);
	try {
		store.importRoster([{ car_number: '1', car_class: 'R160', retirement_date: 'In-Service' }], '2026-09-06', 1);
		const event = store.db.prepare('INSERT INTO events VALUES(?,?,?)');
		const member = store.db.prepare('INSERT INTO event_cars VALUES(?,?)');
		for (const [id, timestamp] of [['recent-first', now - 86400], ['old', now - 30 * 86400],
			['boundary', now - 7 * 86400], ['recent-last', now - 3600]] as const) {
			event.run(id, timestamp, JSON.stringify({ timestamp }));
			member.run(id, 'nyct:R160:1');
		}
		await packs.start();
		const job = await packs.request({ equipment: ['R160'], yards: [], historyDays: 7 }, now);
		const result = await ready(packs, job.jobId);
		assert.equal(result?.state, 'ready', JSON.stringify(result));
		const archive = await readFile(join(output, `${result!.manifest!.id}.jsonl.gz`));
		const events = gunzipSync(archive).toString('utf8').trimEnd().split('\n').map(line => JSON.parse(line))
			.filter(line => line[0] === 'event').map(line => line[1]);
		assert.deepEqual(events, ['recent-first', 'boundary', 'recent-last']);
	} finally { await packs.stop(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('v2 route validates selections and serves ranged immutable archives', async () => {
	const dir = await mkdtemp(join(tmpdir(), 'sfn-pack-api-'));
	const source = join(dir, 'fleet.sqlite'), store = seed(source);
	const service = new TransitService({ cacheDir: dir });
	service.packs = new FleetPackService(source, join(dir, 'packs'));
	const app = await createServer(service);
	try {
		await service.packs.start();
		const prefix = '/subwaysForNerds/api/v1/fleet/offline/v2/';
		const invalid = await app.inject({ method: 'POST', url: prefix + 'packs', payload: { equipment: ['nonexistent'], yards: [], historyDays: 7 } });
		assert.equal(invalid.statusCode, 400);
		assert.equal((await app.inject('/subwaysForNerds/api/v1/fleet/health')).json().offlineV2.available, true);
		const request = await app.inject({ method: 'POST', url: prefix + 'packs', payload: selection });
		assert.equal(request.statusCode, 202);
		const jobId = request.json().jobId;
		const result = await ready(service.packs, jobId);
		assert.equal(result?.state, 'ready');
		const manifest = result!.manifest!;
		const response = await app.inject({ url: manifest.downloadURL, headers: { range: 'bytes=0-19' } });
		assert.equal(response.statusCode, 206);
		assert.equal(response.rawPayload.length, 20);
		assert.equal(response.headers.etag, `"${manifest.archiveSha256}"`);
		assert.equal(response.headers['content-range'], `bytes 0-19/${manifest.archiveByteLength}`);
		assert.equal((await app.inject({ url: manifest.downloadURL, headers: { 'if-none-match': `"${manifest.archiveSha256}"` } })).statusCode, 304);
		assert.equal((await app.inject({ url: manifest.downloadURL, headers: { range: 'bytes=999999999-' } })).statusCode, 416);
		const head = await app.inject({ method: 'HEAD', url: manifest.downloadURL });
		assert.equal(head.statusCode, 200);
		assert.equal(Number(head.headers['content-length']), manifest.archiveByteLength);
		const status = await app.inject(prefix + `packs/${jobId}`);
		assert.equal(status.json().manifest.id, manifest.id);
		const expired = new Date(Date.now() - 25 * 3_600_000);
		await utimes(join(dir, 'packs', `${manifest.id}.jsonl.gz`), expired, expired);
		await service.packs.cleanup();
		assert.equal((await app.inject(manifest.downloadURL)).statusCode, 404, 'Completed range and HEAD responses release the file');
	} finally { await app.close(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('v2 pack holds one WAL view while live boards and fleet observations continue', async t => {
	const dir = await mkdtemp(join(tmpdir(), 'sfn-pack-concurrent-'));
	const source = join(dir, 'fleet.sqlite'), store = seed(source);
	const service = new TransitService({ cacheDir: dir });
	service.refreshBoards(now);
	service.packs = new FleetPackService(source, join(dir, 'packs'));
	const app = await createServer(service);
	const insert = store.db.prepare('INSERT INTO events VALUES(?,?,?)');
	const member = store.db.prepare('INSERT INTO event_cars VALUES(?,?)');
	const last = store.all(now).find(car => car.last)!.last!;
	const extraEvents = 10_000;
	store.db.exec('BEGIN');
	for (let i = 0; i < extraEvents; i++) {
		const id = `retained-${i}`, timestamp = now - 1000 + i % 1000;
		insert.run(id, timestamp, JSON.stringify({ ...last, timestamp, location: `Recorded stop ${i}` }));
		for (const car of last.cars) member.run(id, car);
	}
	store.db.exec('COMMIT');
	let writes = 0, boardResponses = 0, exporting = true;
	const requests: Promise<unknown>[] = [], latencies: number[] = [];
	const timer = setInterval(() => {
		writes++;
		store.observe([{ namespace: 'nyct', cars: [{ number: '1', type: 'R160' }, { number: '2', type: 'R211' }],
			observation: { ...last, timestamp: now + writes, location: `Concurrent stop ${writes}` } }], now + writes);
		const requestedAt = performance.now();
		requests.push(app.inject('/subwaysForNerds/api/v1/stations/602/board').then(response => {
			assert.equal(response.statusCode, 200);
			if (exporting) boardResponses++;
			latencies.push(performance.now() - requestedAt);
		}));
	}, 5);
	try {
		await service.packs.start();
		const started = performance.now();
		const job = await service.packs.request({ equipment: [], yards: [], historyDays: 30 }, now);
		const state = await ready(service.packs, job.jobId);
		exporting = false; clearInterval(timer);
		await Promise.all(requests);
		assert.equal(state?.state, 'ready', JSON.stringify(state));
		assert.ok(writes > 0 && boardResponses > 0);
		const manifest = state!.manifest!;
		const capturedWrites = manifest.observedAt! - now;
		assert.equal(manifest.counts.events, 3 + extraEvents + capturedWrites);
		const lines = gunzipSync(await readFile(join(dir, 'packs', `${manifest.id}.jsonl.gz`))).toString('utf8').trimEnd().split('\n').map(line => JSON.parse(line));
		const cars = lines.filter(line => line[0] === 'car').map(line => JSON.parse(line[2]));
		assert.ok(cars.filter(car => car.last).every(car => car.last.timestamp === manifest.observedAt));
		latencies.sort((a, b) => a - b);
		t.diagnostic(`Packed ${manifest.counts.events} events into ${manifest.archiveByteLength} bytes in ${Math.round(performance.now() - started)} ms; ${boardResponses} concurrent board responses, p95 ${Math.ceil(latencies[Math.floor(latencies.length * 0.95)])} ms`);
	} finally { exporting = false; clearInterval(timer); await app.close(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('v2 low disk cleans staging and reports unavailable', async () => {
	const dir = await mkdtemp(join(tmpdir(), 'sfn-pack-space-'));
	const source = join(dir, 'fleet.sqlite'), store = seed(source);
	try {
		for (const availableBytesForTests of [[0], [Number.MAX_SAFE_INTEGER, 0]]) {
			const packs = new FleetPackService(source, join(dir, 'packs'), { availableBytesForTests });
			try {
				await packs.start();
				const job = await packs.request(selection, now);
				assert.equal((await ready(packs, job.jobId))?.state, 'unavailable');
				assert.deepEqual(await readdir(join(dir, 'packs')), []);
			} finally { await packs.stop(); }
		}
	} finally { store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('v2 failed replacement leaves the previous artifact readable after restart', async () => {
	const dir = await mkdtemp(join(tmpdir(), 'sfn-pack-recovery-'));
	const source = join(dir, 'fleet.sqlite'), output = join(dir, 'packs'), store = seed(source);
	let first = new FleetPackService(source, output);
	try {
		await first.start();
		const initial = await first.request(selection, now);
		const saved = (await ready(first, initial.jobId))!.manifest!;
		await first.stop();
		await writeFile(join(output, '.building-interrupted.jsonl.gz'), 'incomplete');
		await writeFile(join(output, `${'f'.repeat(64)}.jsonl.gz`), 'orphan');
		const resumed = new FleetPackService(source, output, { availableBytesForTests: [0] });
		first = resumed;
		await resumed.start();
		assert.ok(!(await readdir(output)).some(name => name.startsWith('.building-') || name.startsWith('f'.repeat(64))));
		const failure = await resumed.request({ equipment: [], yards: [], historyDays: 30 }, now);
		assert.equal((await ready(resumed, failure.jobId))?.state, 'unavailable');
		const previous = await resumed.artifact(saved.id);
		assert.equal(previous?.stat.size, saved.archiveByteLength);
		await previous?.file.close(); previous?.release();
		assert.equal((await readFile(join(output, `${saved.id}.jsonl.gz`))).length, saved.archiveByteLength);
	} finally { await first.stop(); store.close(); await rm(dir, { recursive: true, force: true }); }
});
