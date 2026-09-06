import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { FleetService } from '../server/fleet';
import { FleetStore } from '../server/fleet-store.mjs';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';
import { decode } from '../server/decode';

test('fleet APIs use local paginated inventory, reject malformed filters, and isolate worker failures', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'sfn-fleet-api-'));
  let upstream = 0;
  const service = new TransitService({ fetcher: (async () => { upstream++; throw new Error('No request-time fetch'); }) as typeof fetch });
  const raw = decode(new Uint8Array(await readFile(new URL('fixtures/gtfs.pb', import.meta.url))));
  service.accept('gtfs', raw, Number(raw.header.timestamp));
  service.fleet = new FleetService(join(dir, 'fleet.sqlite'));
  const app = await createServer(service);
  try {
    await service.fleet.ready;
    const list = await app.inject('/subwaysForNerds/api/v1/fleet');
    assert.equal(list.statusCode, 200); assert.equal(list.json().rows.length, 100);
    assert.ok(list.json().coverage.find((c: any) => c.category === 'passenger').count > 4000);
    const second = await app.inject('/subwaysForNerds/api/v1/fleet?page=2');
    assert.notEqual(second.json().rows[0].id, list.json().rows[0].id);
    assert.equal((await app.inject('/subwaysForNerds/api/v1/fleet?page=-1')).statusCode, 400);
    assert.equal((await app.inject('/subwaysForNerds/api/v1/fleet/cars/not-recorded')).statusCode, 404);
    const work = await app.inject('/subwaysForNerds/api/v1/fleet?q=OL912');
    assert.equal(work.json().total, 1);
    const car = await app.inject('/subwaysForNerds/api/v1/fleet/cars/' + encodeURIComponent(work.json().rows[0].cars[0].id));
    assert.equal(car.statusCode, 200); assert.equal(car.json().cars[0].last, undefined);
    const detail = [...service.details.values()][0].train;
    const result = await app.inject('/subwaysForNerds/api/v1/trips/transfers?' + new URLSearchParams({ key: detail.key, stopId: detail.stops[0].id }));
    assert.equal(result.statusCode, 200); assert.ok(result.json().message);
    assert.equal((await app.inject('/subwaysForNerds/api/v1/trips/transfers?sequence=no')).statusCode, 400);
    await service.fleet.worker.terminate();
    assert.equal((await app.inject('/subwaysForNerds/api/v1/fleet')).statusCode, 503);
    assert.equal((await app.inject('/subwaysForNerds/api/v1/stations/602/board')).statusCode, 200);
    assert.equal(upstream, 0);
  } finally { await app.close(); await rm(dir, { recursive: true, force: true }); }
});

test('backup CLI includes WAL data and refuses overwrite; unsupported migrations are nonmutating', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'sfn-fleet-backup-'));
  const source = join(dir, 'fleet.sqlite'), snapshot = join(dir, 'snapshot.sqlite');
  const db = new FleetStore(source);
  try {
    db.importRoster([{ car_number: '1', car_class: 'R160', retirement_date: 'In-Service' }], '2026-09-06', 1);
    execFileSync(process.execPath, ['scripts/fleet-db.mjs', 'backup', source, snapshot]);
    assert.throws(() => execFileSync(process.execPath, ['scripts/fleet-db.mjs', 'backup', source, snapshot], { stdio: 'pipe' }));
    const restored = new FleetStore(snapshot);
    assert.equal(restored.all(1800000000).length, 1); restored.close();
    const future = new DatabaseSync(join(dir, 'future.sqlite'));
    future.exec('CREATE TABLE migrations(version INTEGER); INSERT INTO migrations VALUES(2)');
    assert.throws(() => new FleetStore(join(dir, 'future.sqlite')), /Unsupported/);
    assert.equal(future.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type='table'").get()!.n, 1);
    future.close();
  } finally { db.close(); await rm(dir, { recursive: true, force: true }); }
});
