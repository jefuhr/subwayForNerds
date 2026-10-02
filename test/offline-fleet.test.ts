import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { gunzipSync } from 'node:zlib';
import type { FleetOfflineManifest } from '../shared/offline';
import { FleetStore } from '../server/fleet-store.mjs';
import { FleetOfflineService } from '../server/fleet-offline';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';
import type { FleetCar, FleetSnapshot } from '../shared/fleet';

const now = 1800000000;
const observation = (timestamp: number, location = 'At Test'): FleetSnapshot => ({
  namespace: 'nyct', cars: [{ number: '1', type: 'R160A' }, { number: '2', type: 'R160B' }],
  observation: { timestamp, locationTimestamp: timestamp - 5, location, route: 'E', tripKey: 'trip|special /?', next: { name: 'Next', stationId: '602', time: timestamp + 90 } },
});
function seed(file: string) {
  const store = new FleetStore(file);
  store.importRoster([
    { car_number: '1', car_class: 'R160', retirement_date: 'In-Service' },
    { car_number: '1', car_class: 'R32', retirement_date: 'Retired' },
    { car_number: '2', car_class: 'R160', retirement_date: 'In-Service' },
    { car_number: '3', car_class: 'R160', retirement_date: 'Scrapped' },
  ], '2026-09-06', 1);
  store.importSupplement({ cars: [], sources: [{ url: 'https://example.org/roster', date: '2026-09-06', note: 'Supplement provenance' }], yardRules: [{ routes: ['E'], name: 'Jamaica', url: 'https://example.org/yard', date: '2026-09-06', note: 'Route estimate' }] });
  store.observe([observation(now - 31 * 86400, 'Old')], now - 31 * 86400);
  for (let i = 250; i >= 0; i--) store.observe([observation(now - i, `At Stop ${i}`)], now - i);
  return store;
}

async function unpack(output: string, manifest: FleetOfflineManifest, destination: string) {
  const compressed = await readFile(join(output, `${manifest.id}.sqlite.gz`));
  assert.equal(manifest.compression, 'gzip');
  assert.equal(compressed.length, manifest.compressedByteLength);
  assert.equal(createHash('sha256').update(compressed).digest('hex'), manifest.compressedSha256);
  const bytes = gunzipSync(compressed);
  assert.equal(bytes.length, manifest.byteLength);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), manifest.sha256);
  await writeFile(destination, bytes);
  return new DatabaseSync(destination, { readOnly: true });
}

test('offline export includes full history, complete roster/provenance and materialized historical cars', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'sfn-offline-'));
  const source = join(dir, 'fleet.sqlite'), output = join(dir, 'offline');
  const store = seed(source), offline = new FleetOfflineService(source, output);
  try {
    const expected: FleetCar[] = JSON.parse(JSON.stringify(store.all(now).map(car => ({ ...car, reporting: false }))));
    assert.equal(store.detail('nyct:R160:1', now)!.history.length, 200);
    const building = offline.rebuild(now);
    assert.equal(offline.rebuild(now + 1), building, 'Concurrent callers share one export');
    const manifest = await building;
    assert.equal(manifest.schemaVersion, 1);
    assert.equal(manifest.historyStart, now - 30 * 86400);
    assert.equal(manifest.historyEnd, now);
    assert.equal(manifest.observedAt, now);
    assert.equal(manifest.counts.events, 251);
    assert.equal(manifest.counts.cars, 4);
    assert.equal(manifest.counts.assertions, 4);
    const db = await unpack(output, manifest, join(dir, 'unpacked.sqlite'));
    try {
      assert.equal(db.prepare('PRAGMA user_version').get()!.user_version, 1);
      assert.equal(db.prepare('PRAGMA integrity_check').get()!.integrity_check, 'ok');
      assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
      const cars = db.prepare('SELECT data FROM cars ORDER BY id').all().map(row => JSON.parse(String(row.data))) as FleetCar[];
      assert.deepEqual(cars, expected.sort((a, b) => a.id.localeCompare(b.id)));
      assert.equal(cars.find(c => c.id === 'nyct:R160:1')!.estimatedYard!.name, 'Jamaica');
      assert.ok(cars.every(c => c.reporting === false));
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM event_cars').get()!.n, 502);
      assert.equal(db.prepare('SELECT MIN(timestamp) AS n FROM events').get()!.n, now - 250);
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM assertions').get()!.n, 4);
      assert.ok(db.prepare("SELECT data FROM meta WHERE key='supplement'").get());
      assert.ok(!db.prepare("SELECT name FROM sqlite_master WHERE name='migrations'").get());
      assert.ok(!db.prepare('PRAGMA table_info(cars)').all().some(row => row.name === 'signature' || row.name === 'last'));
      const history = db.prepare('SELECT DISTINCT e.id,e.timestamp FROM events e JOIN event_cars ec ON ec.event_id=e.id WHERE ec.car_id IN (?,?) ORDER BY e.timestamp DESC,e.id DESC').all('nyct:R160:1', 'nyct:R160:2');
      assert.equal(history.length, 251);
    } finally { db.close(); }
    assert.deepEqual(JSON.parse(await readFile(join(output, 'manifest.json'), 'utf8')), manifest);
    assert.equal((await readdir(output)).filter(name => name.startsWith('.')).length, 0);
  } finally { await offline.stop(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('publication preserves last good on failure, restores gzip, caps retention and keeps open downloads readable', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'sfn-offline-recovery-'));
  const source = join(dir, 'fleet.sqlite'), output = join(dir, 'offline');
  const store = seed(source), offline = new FleetOfflineService(source, output);
  let restored: FleetOfflineService | undefined;
  try {
    const first = await offline.rebuild(now);
    const firstFile = join(output, `${first.id}.sqlite.gz`);
    const manifestBytes = await readFile(join(output, 'manifest.json'));
    store.db.exec('UPDATE migrations SET version=99');
    await assert.rejects(offline.rebuild(now + 1), /Unsupported/);
    assert.deepEqual(offline.manifest, first);
    assert.deepEqual(await readFile(join(output, 'manifest.json')), manifestBytes);
    assert.equal((await stat(firstFile)).size, first.compressedByteLength);
    store.db.exec('UPDATE migrations SET version=1');
    const second = await offline.rebuild(now + 2);
    assert.notEqual(first.id, second.id);
    assert.ok(await stat(firstFile));
    const inProgress = await offline.artifact(first.id, true);
    assert.ok(inProgress);
    await utimes(firstFile, new Date(0), new Date(0));
    await utimes(join(output, `${second.id}.sqlite.gz`), new Date(0), new Date(0));
    await offline.cleanup();
    await assert.rejects(stat(firstFile), { code: 'ENOENT' });
    // An already-open download remains readable after the old path is pruned;
    // even an expired last-good publication remains available for new requests.
    try { assert.equal((await inProgress.file.readFile()).length, first.compressedByteLength); }
    finally { await inProgress.file.close(); }
    assert.ok(await stat(join(output, `${second.id}.sqlite.gz`)));
    await offline.rebuild(now + 3);
    const latest = await offline.rebuild(now + 4);
    assert.equal((await readdir(output)).filter(name => name.endsWith('.sqlite.gz')).length, 2);
    await writeFile(join(output, '.building-abandoned.sqlite'), 'incomplete');
    restored = new FleetOfflineService(source, output);
    await restored.restore();
    assert.deepEqual(restored.manifest, latest);
    await assert.rejects(stat(join(output, '.building-abandoned.sqlite')), { code: 'ENOENT' });
  } finally { await restored?.stop(); await offline.stop(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('offline API streams immutable snapshots with range resume and isolates unavailable exports from boards', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'sfn-offline-api-'));
  const source = join(dir, 'fleet.sqlite');
  const store = seed(source), service = new TransitService();
  service.refreshBoards(now);
  service.offline = new FleetOfflineService(source, join(dir, 'offline'), { availableBytesForTests: [0] });
  const app = await createServer(service);
  try {
    const prefix = '/subwaysForNerds/api/v1/fleet/offline/';
    const unavailable = await app.inject(prefix + 'manifest');
    assert.equal(unavailable.statusCode, 503);
    assert.equal(unavailable.headers['retry-after'], '60');
    await assert.rejects(service.offline.rebuild(now), /Insufficient disk space/);
    const failedHealth = (await app.inject('/subwaysForNerds/api/v1/fleet/health')).json();
    assert.equal(failedHealth.offline.available, false);
    assert.equal(failedHealth.offline.generatedAt, null);
    assert.match(failedHealth.offline.error, /Insufficient disk space/);
    assert.equal((await app.inject(prefix + 'manifest')).statusCode, 503);
    assert.equal((await app.inject('/subwaysForNerds/api/v1/stations/602/board')).statusCode, 200);
    await service.offline.stop();
    service.offline = new FleetOfflineService(source, join(dir, 'offline'));
    const manifest = await service.offline.rebuild(now);
    assert.deepEqual((await app.inject('/subwaysForNerds/api/v1/fleet/health')).json().offline,
      { available: true, generatedAt: now, error: null });
    const response = await app.inject(prefix + 'manifest');
    assert.equal(response.statusCode, 200);
    const url: string = response.json().downloadURL;
    assert.equal(url, prefix + `snapshots/${manifest.id}.sqlite.gz`);
    const complete = await app.inject({ url, headers: { 'accept-encoding': 'gzip' } });
    assert.equal(complete.statusCode, 200);
    assert.equal(complete.rawPayload.length, manifest.compressedByteLength!);
    assert.equal(complete.headers['content-encoding'], undefined);
    assert.equal(complete.headers['content-type'], 'application/gzip');
    assert.equal(gunzipSync(complete.rawPayload).length, manifest.byteLength);
    assert.equal(complete.headers.etag, `"${manifest.compressedSha256}"`);
    // Existing raw snapshots stay downloadable during a gzip migration.
    const rawFile = join(dir, 'offline', `${manifest.id}.sqlite`);
    await writeFile(rawFile, gunzipSync(complete.rawPayload));
    const legacy = await app.inject(url.replace(/\.gz$/, ''));
    assert.equal(legacy.statusCode, 200);
    assert.equal(legacy.headers.etag, `"${manifest.sha256}"`);
    assert.equal(legacy.rawPayload.length, manifest.byteLength);
    await utimes(rawFile, new Date(0), new Date(0));
    await service.offline.cleanup();
    assert.ok(await stat(join(dir, 'offline', `${manifest.id}.json`)), 'Pruning legacy raw must preserve gzip metadata');
    const partial = await app.inject({ url, headers: { range: 'bytes=10-29', 'if-range': String(complete.headers.etag) } });
    assert.equal(partial.statusCode, 206);
    assert.equal(partial.headers['content-range'], `bytes 10-29/${manifest.compressedByteLength!}`);
    assert.deepEqual(partial.rawPayload, complete.rawPayload.subarray(10, 30));
    const suffix = await app.inject({ url, headers: { range: 'bytes=-20' } });
    assert.deepEqual(suffix.rawPayload, complete.rawPayload.subarray(-20));
    const tail = await app.inject({ url, headers: { range: `bytes=${manifest.compressedByteLength! - 10}-` } });
    assert.equal(tail.rawPayload.length, 10);
    const mismatched = await app.inject({ url, headers: { range: 'bytes=0-9', 'if-range': '"different"' } });
    assert.equal(mismatched.statusCode, 200);
    assert.equal(mismatched.rawPayload.length, manifest.compressedByteLength!);
    assert.equal((await app.inject({ url, headers: { 'if-none-match': String(complete.headers.etag) } })).statusCode, 304);
    for (const range of ['bytes=999999999-', 'bytes=20-10', 'bytes=-0', 'bytes=0-1,3-4']) {
      const invalid = await app.inject({ url, headers: { range } });
      assert.equal(invalid.statusCode, 416);
      assert.equal(invalid.headers['content-range'], `bytes */${manifest.compressedByteLength!}`);
    }
    const head = await app.inject({ method: 'HEAD', url });
    assert.equal(head.statusCode, 200);
    assert.equal(Number(head.headers['content-length']), manifest.compressedByteLength!);
    assert.equal(head.rawPayload.length, 0);
    assert.equal((await app.inject(prefix + 'snapshots/invalid.sqlite')).statusCode, 404);
  } finally { await app.close(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('a large export stays consistent while WAL observations and board requests continue', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'sfn-offline-concurrent-'));
  const source = join(dir, 'fleet.sqlite'), output = join(dir, 'offline');
  const store = seed(source), service = new TransitService();
  service.refreshBoards(now);
  service.offline = new FleetOfflineService(source, output);
  const app = await createServer(service);
  const extraEvents = 20000;
  const insert = store.db.prepare('INSERT INTO events VALUES(?,?,?)');
  const member = store.db.prepare('INSERT INTO event_cars VALUES(?,?)');
  const last = store.all(now).find(car => car.last)!.last!;
  store.db.exec('BEGIN');
  for (let i = 0; i < extraEvents; i++) {
    const id = `retained-${i}`, timestamp = now - 1000 + i % 1000;
    insert.run(id, timestamp, JSON.stringify({ ...last, timestamp, location: `Recorded stop ${i}` }));
    for (const car of last.cars) member.run(id, car);
  }
  store.db.exec('COMMIT');
  let writes = 0, boardResponses = 0, exporting = true;
  const requests: Promise<unknown>[] = [], latencies: number[] = [];
  const started = performance.now();
  const timer = setInterval(() => {
    writes++;
    store.observe([observation(now + writes, `Concurrent stop ${writes}`)], now + writes);
    const requestedAt = performance.now();
    requests.push(app.inject('/subwaysForNerds/api/v1/stations/602/board').then(response => {
      assert.equal(response.statusCode, 200);
      if (exporting) boardResponses++;
      latencies.push(performance.now() - requestedAt);
    }));
  }, 5);
  try {
    const manifest = await service.offline.rebuild(now);
    exporting = false; clearInterval(timer);
    await Promise.all(requests);
    assert.ok(writes > 0);
    assert.ok(boardResponses > 0, 'Board requests must complete during export');
    const capturedWrites = manifest.observedAt! - now;
    assert.equal(manifest.counts.events, 251 + extraEvents + capturedWrites);
    const db = await unpack(output, manifest, join(dir, 'unpacked.sqlite'));
    try {
      assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(), []);
      const reports = db.prepare("SELECT json_extract(data,'$.last.timestamp') AS timestamp FROM cars WHERE json_extract(data,'$.last.timestamp') IS NOT NULL").all();
      assert.ok(reports.every(report => report.timestamp === manifest.observedAt));
      assert.equal(db.prepare('SELECT MAX(timestamp) AS timestamp FROM events').get()!.timestamp, manifest.observedAt);
      assert.equal(db.prepare('SELECT COUNT(*) AS n FROM event_cars').get()!.n, manifest.counts.events * 2);
    } finally { db.close(); }
    latencies.sort((a, b) => a - b);
    t.diagnostic(`Exported ${manifest.counts.events} events in ${Math.round(performance.now() - started)} ms; ${boardResponses} concurrent board responses, p95 ${Math.ceil(latencies[Math.floor(latencies.length * 0.95)])} ms`);
  } finally { clearInterval(timer); await app.close(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

test('low space aborts before export and during export or gzip, cleans staging, and preserves current publication', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'sfn-offline-space-'));
  const source = join(dir, 'fleet.sqlite'), output = join(dir, 'offline');
  const store = seed(source), initial = new FleetOfflineService(source, output);
  try {
    const manifest = await initial.rebuild(now);
    const original = await readFile(join(output, 'manifest.json'));
    // First check is preflight. After 4 cars + 4 assertions + 1 consist + 251
    // events + 502 members, checks 2-3 occur while inserting; 4 at commit;
    // 5 before gzip; 6-7 guard the header and final gzip output chunks.
    for (const availableBytesForTests of [[0], [1e12, 0], [1e12, 1e12, 1e12, 1e12, 1e12, 1e12, 0]]) {
      const offline = new FleetOfflineService(source, output, { availableBytesForTests });
      try {
        await offline.restore();
        await assert.rejects(offline.rebuild(now + 1), /Insufficient disk space/);
        assert.deepEqual(offline.manifest, manifest);
        assert.deepEqual(await readFile(join(output, 'manifest.json')), original);
        assert.equal((await readdir(output)).filter(name => name.startsWith('.')).length, 0);
        assert.equal((await readdir(output)).filter(name => name.endsWith('.sqlite')).length, 0);
        assert.ok(await stat(join(output, `${manifest.id}.sqlite.gz`)));
      } finally { await offline.stop(); }
    }
  } finally { await initial.stop(); store.close(); await rm(dir, { recursive: true, force: true }); }
});
