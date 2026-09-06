import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { Worker } from 'node:worker_threads';
import { bundledCatalog, fromSocrata, makeCatalog } from './catalog';
import { decode } from './decode';
import { FEED_ROUTES, normalizeFeed, normalizeAlerts, buildBoard, nowSeconds } from './transit';
import type { Board, ServiceAlert, SourceState, StationContext, Train } from '../shared/types';

const upstream = 'https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/';
export interface FeedSlot { state: SourceState; raw?: any; trains: Map<string, Train>; digest?: string }
export class TransitService {
  catalog = bundledCatalog;
  slots = new Map<string, FeedSlot>();
  alerts: ServiceAlert[] = [];
  boards = new Map<string, Board>();
  details = new Map<string, { train: Train; raw: unknown }>();
  entrances: Record<string, string>[] = [];
  equipment: Record<string, string>[] = [];
  outages: Record<string, string>[] = [];
  contextStates = new Map<string, SourceState>();
  timers = new Set<ReturnType<typeof setTimeout>>();
  stopped = false;
  revision = 0;
  readonly cacheDir: string;
  constructor(readonly options: { fixtureDir?: string; cacheDir?: string; fetcher?: typeof fetch } = {}) {
    this.cacheDir = options.cacheDir || process.env.STATE_DIR || 'state';
    for (const id of [...Object.keys(FEED_ROUTES), 'subway-alerts']) this.slots.set(id, { state: { id, timestamp: null, fetchedAt: null, error: null }, trains: new Map() });
  }
  async request(url: string) {
    const result = await (this.options.fetcher || fetch)(url, { signal: AbortSignal.timeout(12000), headers: { 'User-Agent': 'SubwaysForNerds/0.1' } });
    if (!result.ok) throw new Error(`Upstream HTTP ${result.status}`);
    return result;
  }
  async persist(name: string, value: unknown) {
    await mkdir(this.cacheDir, { recursive: true });
    const file = path.join(this.cacheDir, `${name}.json`);
    await writeFile(file + '.tmp', JSON.stringify(value));
    await rename(file + '.tmp', file);
  }
  async restore(name: string): Promise<any | undefined> {
    try { return JSON.parse(await readFile(path.join(this.cacheDir, `${name}.json`), 'utf8')); } catch { return undefined; }
  }
  refreshBoards() {
    const states = [...this.slots.values()].map(s => ({ ...s.state }));
    const all = [...this.slots.values()].flatMap(s => [...s.trains.values()]);
    const partToStation = new Map(this.catalog.flatMap(s => s.parts.map(p => [p.id, s.id] as const)));
    const byStation = new Map<string, Train[]>();
    for (const t of all) {
      for (const id of new Set(t.stops.map(s => partToStation.get(s.id.replace(/[NS]$/, ''))).filter(Boolean))) {
        const group = byStation.get(id!) || []; group.push(t); byStation.set(id!, group);
      }
    }
    const boards = new Map<string, Board>();
    for (const s of this.catalog) boards.set(s.id, buildBoard(s, byStation.get(s.id) || [], states, this.alerts, this.catalog));
    this.boards = boards;
    this.details.clear();
    for (const slot of this.slots.values()) for (const train of slot.trains.values()) {
      const raw = slot.raw?.entity?.filter((e: any) => (e.trip_update?.trip?.trip_id || e.vehicle?.trip?.trip_id) === train.tripId);
      this.details.set(train.key, { train, raw });
    }
    this.revision++;
  }
  accept(id: string, raw: any, fetchedAt: number) {
    const slot = this.slots.get(id)!;
    const timestamp = Number(raw.header?.timestamp);
    if (!Number.isFinite(timestamp) || timestamp <= 0) throw new Error('Feed missing a valid timestamp');
    if (slot.state.timestamp != null && timestamp < slot.state.timestamp) throw new Error('Feed timestamp regressed');
    const changed = timestamp !== slot.state.timestamp;
    const recovered = !!slot.state.error;
    slot.state = { id, timestamp, fetchedAt, error: null };
    if (!changed && !recovered) return;
    slot.raw = raw;
    if (id === 'subway-alerts') this.alerts = normalizeAlerts(raw);
    else slot.trains = normalizeFeed(id, raw, this.catalog);
    this.refreshBoards();
  }
  schedule(task: () => Promise<void>, interval: number) {
    let failures = 0;
    const run = async () => {
      if (this.stopped) return;
      try { await task(); failures = 0; } catch (error) { failures++; console.warn(String(error)); }
      if (this.stopped) return;
      const timer = setTimeout(() => { this.timers.delete(timer); void run(); }, Math.min(interval * 2 ** Math.min(failures, 4), 300000));
      this.timers.add(timer);
    };
    void run();
  }
  async start() {
    if (this.options.fixtureDir) {
      for (const id of this.slots.keys()) {
        try {
          const raw = JSON.parse(await readFile(path.join(this.options.fixtureDir, id, '01.json'), 'utf8'));
          this.accept(id, raw, nowSeconds());
        } catch (error) { this.slots.get(id)!.state.error = String(error); }
      }
      this.refreshBoards();
      return;
    }
    await Promise.all([...this.slots.keys()].map(async id => {
      const cached = await this.restore(id);
      if (cached) try { this.accept(id, cached.raw, cached.fetchedAt); } catch { /* Ignore corrupt cache. */ }
    }));
    this.refreshBoards();
    for (const id of this.slots.keys()) this.schedule(async () => {
      const slot = this.slots.get(id)!;
      try {
        const url = upstream + (id === 'subway-alerts' ? 'camsys%2Fsubway-alerts' : `nyct%2F${id}`);
        const response = await this.request(url), bytes = new Uint8Array(await response.arrayBuffer());
        const digest = createHash('sha256').update(bytes).digest('hex');
        if (digest === slot.digest) {
          const recovering = !!slot.state.error;
          slot.state.fetchedAt = nowSeconds(); slot.state.error = null;
          if (recovering) this.refreshBoards();
          return;
        }
        const raw = decode(bytes, id === 'subway-alerts');
        this.accept(id, raw, nowSeconds()); slot.digest = digest;
        await this.persist(id, { raw, fetchedAt: slot.state.fetchedAt });
      } catch (error) { slot.state.error = String(error); this.refreshBoards(); throw error; }
    }, id === 'subway-alerts' ? 60000 : 15000);
    this.startContext();
    this.schedule(() => this.refreshSchedules(), 3600000);
  }
  startContext() {
    const jobs: { id: string; url: string; interval: number; apply: (r: any) => void }[] = [
      { id: 'stations', url: 'https://data.ny.gov/resource/39hk-dx4f.json?$limit=1000', interval: 86400000, apply: r => {
        const next = makeCatalog(r.map(fromSocrata)); if (next.length < 400) throw new Error('Incomplete station catalog');
        this.catalog = next;
        for (const [id, slot] of this.slots) if (slot.raw && id !== 'subway-alerts') slot.trains = normalizeFeed(id, slot.raw, next);
        this.refreshBoards();
      } },
      { id: 'entrances', url: 'https://data.ny.gov/resource/i9wp-a4ja.json?$limit=10000', interval: 86400000, apply: r => { this.entrances = r; } },
      { id: 'equipment', url: upstream + 'nyct%2Fnyct_ene_equipments.json', interval: 60000, apply: r => { this.equipment = r; } },
      { id: 'outages', url: upstream + 'nyct%2Fnyct_ene.json', interval: 60000, apply: r => { this.outages = r; } },
    ];
    for (const job of jobs) {
      this.contextStates.set(job.id, { id: job.id, timestamp: null, fetchedAt: null, error: null });
      this.schedule(async () => {
        const state = this.contextStates.get(job.id)!;
        if (!state.timestamp) {
          const cached = await this.restore(job.id);
          if (cached) { job.apply(cached.rows); Object.assign(state, cached.state); }
        }
        try {
          const response = await this.request(job.url), rows = await response.json();
          if (!Array.isArray(rows)) throw new Error('Unexpected station context response');
          job.apply(rows);
          const modified = response.headers.get('last-modified');
          Object.assign(state, { timestamp: modified && Number.isFinite(Date.parse(modified)) ? Date.parse(modified) / 1000 : nowSeconds(), fetchedAt: nowSeconds(), error: null });
          await this.persist(job.id, { rows, state });
        } catch (error) { state.error = String(error); throw error; }
      }, job.interval);
    }
  }
  async refreshSchedules() {
    const worker = new Worker(new URL('./schedule-worker.mjs', import.meta.url));
    await new Promise<void>((resolve, reject) => {
      worker.once('message', async (result) => {
        try {
          if (result.error) throw new Error(result.error);
          await this.persist('schedules', result);
          this.contextStates.set('schedules', { id: 'schedules', timestamp: result.timestamp, fetchedAt: nowSeconds(), error: null });
          resolve();
        } catch (error) { reject(error); }
      });
      worker.once('error', reject);
      worker.once('exit', code => { if (code !== 0) reject(new Error(`Schedule worker exited ${code}`)); });
    });
  }
  context(id: string): StationContext | undefined {
    const station = this.catalog.find(s => s.id === id); if (!station) return;
    const equipment = this.equipment.filter(e => String(e.stationcomplexid) === id || station.parts.some(p => e.elevatorsgtfsstopid?.split(/[ ,/]+/).includes(p.id)));
    const ids = new Set(equipment.map(e => e.equipmentno));
    return { entrances: this.entrances.filter(e => String(e.complex_id) === id), equipment,
      outages: this.outages.filter(e => ids.has(e.equipment || e.equipmentno)), sources: [...this.contextStates.values()] };
  }
  stop() { this.stopped = true; for (const timer of this.timers) clearTimeout(timer); this.timers.clear(); }
}
