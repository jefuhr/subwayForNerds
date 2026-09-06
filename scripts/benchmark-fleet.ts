import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { TransitService } from '../server/service';
import { FleetService } from '../server/fleet';
import { createServer } from '../server/index';
import { decode } from '../server/decode';
import type { FleetSnapshot } from '../shared/fleet';

const dir = await mkdtemp(join(tmpdir(), 'sfn-fleet-bench-'));
const service = new TransitService();
const raw = decode(new Uint8Array(await readFile(new URL('../test/fixtures/gtfs.pb', import.meta.url))));
service.accept('gtfs', raw, Number(raw.header.timestamp));
const app = await createServer(service);
let timer: ReturnType<typeof setInterval> | undefined;
try {
  const address = await app.listen({ host: '127.0.0.1', port: 0 });
  const url = address + '/subwaysForNerds/api/v1/stations/602/board';
  async function phase() {
    const times: number[] = [];
    for (let batch = 0; batch < 100; batch++) await Promise.all(Array.from({ length: 8 }, async () => {
      const start = performance.now(); const r = await fetch(url); await r.arrayBuffer();
      if (!r.ok) throw new Error('Departure request failed'); times.push(performance.now() - start);
    }));
    times.sort((a, b) => a - b);
    return { p50: times[Math.floor(times.length * .5)], p95: times[Math.floor(times.length * .95)] };
  }
  await phase();
  service.fleet = new FleetService(join(dir, 'fleet.sqlite')); await service.fleet.ready;
  const baseline = [], loaded = [];
  for (let round = 0; round < 3; round++) {
    baseline.push(await phase());
    let revision = 0;
    const ingest = () => {
      const now = Math.floor(Date.now() / 1000); revision++;
      const snapshots: FleetSnapshot[] = Array.from({ length: 100 }, (_, i) => ({ namespace: 'nyct',
        cars: Array.from({ length: 10 }, (_, c) => ({ number: String(100000 + i * 10 + c), type: 'R160' })),
        observation: { timestamp: now, locationTimestamp: now, location: `At synthetic benchmark station ${revision}`, route: 'Q', tripKey: `bench-${i}`, next: { name: 'Synthetic next stop', time: now + 120 } } }));
      service.fleet!.observe(snapshots, now);
    };
    ingest(); timer = setInterval(ingest, 200); // Much faster than production's 10-second consist poll.
    loaded.push(await phase()); clearInterval(timer); timer = undefined;
    await service.fleet.call('list', {}, Math.floor(Date.now() / 1000));
  }
  const median = (a: number[]) => a.sort((a, b) => a - b)[1];
  const before = median(baseline.map(r => r.p95)), after = median(loaded.map(r => r.p95));
  console.log(JSON.stringify({ requestsPerPhase: 800, concurrency: 8, baseline, loaded, medianP95ChangePercent: 100 * (after / before - 1) }, null, 2));
} finally { if (timer) clearInterval(timer); await app.close(); await rm(dir, { recursive: true, force: true }); }
