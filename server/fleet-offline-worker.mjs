import { parentPort, workerData } from 'node:worker_threads';
import { DatabaseSync } from 'node:sqlite';
import { createReadStream, createWriteStream, statfsSync } from 'node:fs';
import { stat, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createGzip } from 'node:zlib';
import { dirname } from 'node:path';
import { readFleetCars } from './fleet-store.mjs';

let source, output;
const reserve = workerData.reserveBytes ?? 2 * 1024 ** 3;
let checks = 0, rows = 0;
function space(required = 16 * 1024 ** 2) {
  const disk = statfsSync(dirname(workerData.destination));
  const sequence = workerData.availableBytesForTests;
  const available = sequence ? sequence[Math.min(checks++, sequence.length - 1)] : disk.bavail * disk.bsize;
  if (available < reserve + required) {
    const error = new Error(`Insufficient disk space for offline fleet export: ${available} bytes available, ${reserve + required} required including reserve`);
    error.code = 'ENOSPC'; throw error;
  }
}
function progress() { if (++rows % 256 === 0) space(); }
try {
  source = new DatabaseSync(workerData.source, { readOnly: true });
  source.exec('PRAGMA busy_timeout=3000; BEGIN');
  // The first read fixes one WAL snapshot for every table in this export.
  const version = source.prepare('SELECT MAX(version) AS version FROM migrations').get()?.version;
  if (version !== 1) throw new Error('Unsupported fleet source schema');
  const pages = Number(source.prepare('PRAGMA page_count').get().page_count);
  const freePages = Number(source.prepare('PRAGMA freelist_count').get().freelist_count);
  const pageSize = Number(source.prepare('PRAGMA page_size').get().page_size);
  // Budget the live source plus up to 2 GiB of compression headroom. Check
  // continuously as either file grows; this is a preflight, not a fit promise.
  const liveBytes = (pages - freePages) * pageSize;
  space(liveBytes + Math.min(liveBytes, 2 * 1024 ** 3) + 16 * 1024 ** 2);
  const generatedAt = workerData.generatedAt ?? Math.floor(Date.now() / 1000);
  const historyStart = generatedAt - 30 * 86400;
  const historyEnd = Math.max(generatedAt, Number(source.prepare('SELECT MAX(timestamp) AS timestamp FROM events').get()?.timestamp || 0));
  const observedAt = JSON.parse(source.prepare("SELECT data FROM meta WHERE key='observedAt'").get()?.data || 'null');
  // Empty current associations intentionally make every saved report historical.
  const cars = readFleetCars(source, generatedAt);
  output = new DatabaseSync(workerData.destination);
  output.exec(`PRAGMA journal_mode=DELETE; PRAGMA foreign_keys=ON; PRAGMA user_version=1;
    CREATE TABLE meta(key TEXT PRIMARY KEY, data TEXT NOT NULL);
    CREATE TABLE cars(id TEXT PRIMARY KEY, data TEXT NOT NULL);
    CREATE TABLE assertions(id TEXT PRIMARY KEY, car_id TEXT NOT NULL REFERENCES cars(id), data TEXT NOT NULL);
    CREATE TABLE consists(id TEXT PRIMARY KEY, data TEXT NOT NULL);
    CREATE TABLE events(id TEXT PRIMARY KEY, timestamp INTEGER NOT NULL, data TEXT NOT NULL);
    CREATE TABLE event_cars(event_id TEXT NOT NULL REFERENCES events(id), car_id TEXT NOT NULL REFERENCES cars(id), PRIMARY KEY(event_id, car_id));
    CREATE INDEX car_category ON cars(json_extract(data, '$.category'));
    CREATE INDEX car_equipment ON cars(json_extract(data, '$.equipment'));
    CREATE INDEX car_fixed_set ON cars(json_extract(data, '$.fixedSet'));
    CREATE INDEX assertion_car_lookup ON assertions(car_id);
    CREATE INDEX event_car_lookup ON event_cars(car_id, event_id);
    CREATE INDEX event_time ON events(timestamp DESC, id DESC);
    CREATE INDEX event_consist_time ON events(json_extract(data, '$.consistId'), timestamp DESC, id DESC);
    BEGIN`);
  const insertCar = output.prepare('INSERT INTO cars VALUES(?,?)');
  for (const car of cars) { insertCar.run(car.id, JSON.stringify({ ...car, reporting: false })); progress(); }
  const counts = { cars: cars.length, consists: 0, events: 0, assertions: 0 };
  for (const table of ['assertions', 'consists']) {
    const insert = output.prepare(`INSERT INTO ${table} VALUES(${table === 'assertions' ? '?,?,?' : '?,?'})`);
    for (const row of source.prepare(`SELECT * FROM ${table} ORDER BY id`).iterate()) {
      insert.run(...(table === 'assertions' ? [row.id, row.car_id, row.data] : [row.id, row.data]));
      counts[table]++;
      progress();
    }
  }
  const insertEvent = output.prepare('INSERT INTO events VALUES(?,?,?)');
  for (const row of source.prepare('SELECT id,timestamp,data FROM events WHERE timestamp>=? ORDER BY timestamp').iterate(historyStart)) {
    insertEvent.run(row.id, row.timestamp, row.data); counts.events++; progress();
  }
  const insertMember = output.prepare('INSERT INTO event_cars VALUES(?,?)');
  for (const row of source.prepare('SELECT ec.event_id,ec.car_id FROM event_cars ec JOIN events e ON e.id=ec.event_id WHERE e.timestamp>=?').iterate(historyStart)) { insertMember.run(row.event_id, row.car_id); progress(); }
  const insertMeta = output.prepare('INSERT INTO meta VALUES(?,?)');
  for (const row of source.prepare("SELECT key,data FROM meta WHERE key IN ('roster','supplement','yardRules','observedAt') ORDER BY key").iterate()) insertMeta.run(row.key, row.data);
  const metadata = { schemaVersion: 1, generatedAt, historyStart, historyEnd, counts,
    ...(typeof observedAt === 'number' && Number.isFinite(observedAt) ? { observedAt } : {}) };
  insertMeta.run('snapshot', JSON.stringify(metadata));
  space(); output.exec('COMMIT');
  source.exec('COMMIT'); source.close(); source = undefined;
  if (output.prepare('PRAGMA quick_check').get()?.quick_check !== 'ok' || output.prepare('PRAGMA foreign_key_check').all().length) throw new Error('Export integrity check failed');
  output.close(); output = undefined;
  const byteLength = (await stat(workerData.destination)).size;
  space(Math.min(byteLength, 2 * 1024 ** 3) + 16 * 1024 ** 2);
  const digest = createHash('sha256'), compressedDigest = createHash('sha256');
  const hashInput = new Transform({ transform(chunk, _encoding, done) { digest.update(chunk); done(null, chunk); } });
  const hashOutput = new Transform({ transform(chunk, _encoding, done) {
    try { space(); compressedDigest.update(chunk); done(null, chunk); } catch (error) { done(error); }
  } });
  await pipeline(createReadStream(workerData.destination), hashInput, createGzip(), hashOutput, createWriteStream(`${workerData.destination}.gz`, { flags: 'wx' }));
  const compressedByteLength = (await stat(`${workerData.destination}.gz`)).size;
  await rm(workerData.destination);
  parentPort.postMessage({ ...metadata, byteLength, sha256: digest.digest('hex'), compression: 'gzip', compressedByteLength, compressedSha256: compressedDigest.digest('hex') });
} catch (error) {
  parentPort.postMessage({ error: String(error), code: error.code });
} finally {
  output?.close(); source?.close(); parentPort.close();
}
