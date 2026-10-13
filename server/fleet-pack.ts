import { Worker } from 'node:worker_threads';
import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { statfsSync } from 'node:fs';
import { mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { readFleetCars } from './fleet-store.mjs';
import { packProgress } from './fleet-pack-progress.mjs';
import type { FleetPackManifest, FleetPackProgress, FleetPackSelection } from '../shared/offline';

const hour = 3_600_000;
const hash = /^[a-f0-9]{64}$/;
const artifact = /^([a-f0-9]{64})\.jsonl\.gz$/;
const maximumCacheBytes = 6 * 1024 ** 3;
type PackState = { jobId: string; state: 'preparing' | 'ready' | 'unavailable'; manifest?: FleetPackManifest; progress?: FleetPackProgress; error?: string };
type PackJob = PackState & { key: string; createdAt: number };
type WorkerResult = Omit<FleetPackManifest, 'id' | 'downloadURL'>;
export interface FleetPackOptions { reserveBytes?: number; availableBytesForTests?: number[]; maximumArtifactBytes?: number; generatedAtForTests?: number }

/** The v2 pack is prepared on demand, independently of the legacy full SQLite export. */
export class FleetPackService {
  ready = false;
  error = '';
  private jobs = new Map<string, PackJob>();
  private active?: { key: string; worker: Worker; done: Promise<void> };
  private reserving = false;
  private retained = new Map<string, FleetPackManifest>();
  private leases = new Map<string, number>();
  private stopped = false;
  private optionsCache?: { at: number; equipment: string[]; yards: string[] };
  constructor(readonly source: string, readonly directory: string, private options: FleetPackOptions = {}) {}

  async start() {
    await mkdir(this.directory, { recursive: true });
    for (const name of await readdir(this.directory)) {
      if (name.startsWith('.building-')) { await rm(join(this.directory, name), { force: true }); continue; }
      if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
      try {
        const manifest = JSON.parse(await readFile(join(this.directory, name), 'utf8')) as FleetPackManifest;
        if (manifest.schemaVersion !== 2 || manifest.format !== 'fleet-jsonl-v2' || manifest.compression !== 'gzip' || !hash.test(manifest.id) ||
          manifest.id !== manifest.archiveSha256 || name !== `${manifest.id}.json` ||
          !Number.isSafeInteger(manifest.archiveByteLength) || manifest.archiveByteLength <= 0 ||
          !Number.isSafeInteger(manifest.uncompressedByteLength) || manifest.uncompressedByteLength <= 0 ||
          !Number.isSafeInteger(manifest.generatedAt) || !Number.isSafeInteger(manifest.historyStart) ||
          !Number.isSafeInteger(manifest.historyEnd) || manifest.historyEnd < manifest.historyStart ||
          !manifest.selection || !Array.isArray(manifest.selection.equipment) || !Array.isArray(manifest.selection.yards) ||
          [...manifest.selection.equipment, ...manifest.selection.yards].some(value => typeof value !== 'string') ||
          ![7, 30].includes(manifest.selection.historyDays) ||
          !manifest.counts || ['cars', 'consists', 'events', 'assertions', 'eventCars', 'matchedCars', 'linkedCars']
            .some(key => !Number.isSafeInteger(manifest.counts[key as keyof typeof manifest.counts]) || manifest.counts[key as keyof typeof manifest.counts] < 0) ||
          (await stat(join(this.directory, `${manifest.id}.jsonl.gz`))).size !== manifest.archiveByteLength) throw new Error('Invalid pack');
        this.retained.set(manifest.id, manifest);
      } catch { await rm(join(this.directory, name), { force: true }); }
    }
    for (const name of await readdir(this.directory)) {
      const match = artifact.exec(name);
      if (match && !this.retained.has(match[1])) await rm(join(this.directory, name), { force: true });
    }
    await this.cleanup();
    this.ready = true;
  }

  availableOptions() {
    const at = Date.now();
    if (this.optionsCache && at - this.optionsCache.at < 5 * 60_000) return this.optionsCache;
    const db = new DatabaseSync(this.source, { readOnly: true });
    try {
      const cars = readFleetCars(db, Math.floor(at / 1000));
      return this.optionsCache = { at,
        equipment: [...new Set(cars.map(car => car.equipment).filter(Boolean))].sort(),
        yards: [...new Set(['unknown', ...cars.map(car => car.estimatedYard?.name || 'unknown')])].sort() };
    } finally { db.close(); }
  }

  private normalize(value: FleetPackSelection): FleetPackSelection {
    if (!value || !Array.isArray(value.equipment) || !Array.isArray(value.yards) ||
      ![7, 30].includes(value.historyDays) || value.equipment.length > 64 || value.yards.length > 64 ||
      [...value.equipment, ...value.yards].some(item => typeof item !== 'string' || item.length > 80)) throw new Error('Invalid fleet pack selection');
    const equipment = [...new Set(value.equipment)].sort(), yards = [...new Set(value.yards)].sort();
    const available = this.availableOptions();
    if (equipment.some(item => !available.equipment.includes(item)) || yards.some(item => !available.yards.includes(item))) throw new Error('Unknown fleet pack filter');
    return { equipment, yards, historyDays: value.historyDays };
  }

  async request(value: FleetPackSelection, generatedAt = this.options.generatedAtForTests ?? Math.floor(Date.now() / 1000)): Promise<PackState> {
    if (this.stopped) throw new Error('Fleet pack service stopped');
    const selection = this.normalize(value), key = JSON.stringify(selection);
    const cached = [...this.retained.values()].filter(item => JSON.stringify(item.selection) === key &&
      generatedAt - item.generatedAt < 3600 && generatedAt >= item.generatedAt)
      .sort((a, b) => b.generatedAt - a.generatedAt)[0];
    if (cached) {
      const existing = [...this.jobs.values()].find(job => job.key === key && job.state === 'ready' && job.manifest?.id === cached.id);
      if (existing) return this.publicState(existing);
      const jobId = randomUUID();
      const job: PackJob = { jobId, key, state: 'ready', manifest: cached, createdAt: Date.now() };
      this.jobs.set(jobId, job);
      return this.publicState(job);
    }
    const running = [...this.jobs.values()].find(job => job.key === key && job.state === 'preparing');
    if (running) return this.publicState(running);
    if (this.active || this.reserving) return { jobId: '', state: 'unavailable', error: 'A fleet pack is already preparing. Retry shortly.' };
    const jobId = randomUUID(), job: PackJob = { jobId, key, state: 'preparing', progress: packProgress('starting'), createdAt: Date.now() };
    this.jobs.set(jobId, job);
    this.reserving = true;
    try { await this.reclaimForBuild(); }
    catch (error) {
      job.state = 'unavailable'; job.error = String(error); this.error = job.error;
      return this.publicState(job);
    } finally { this.reserving = false; }
    if (this.stopped) { job.state = 'unavailable'; job.error = 'Fleet pack service stopped'; return this.publicState(job); }
    const destination = join(this.directory, `.building-${jobId}.jsonl.gz`);
    let worker: Worker;
    try {
      worker = new Worker(new URL('./fleet-pack-worker.mjs', import.meta.url), {
        workerData: { source: this.source, destination, selection, generatedAt, reserveBytes: this.options.reserveBytes,
          availableBytesForTests: this.options.availableBytesForTests, maximumArtifactBytes: this.options.maximumArtifactBytes ?? maximumCacheBytes },
      });
    } catch (error) {
      job.state = 'unavailable'; job.error = String(error); this.error = job.error;
      return this.publicState(job);
    }
    const done = new Promise<void>(resolve => {
      let result: WorkerResult | undefined, failure: Error | undefined;
      const timeout = setTimeout(() => { failure = new Error('Fleet pack preparation timed out'); void worker.terminate(); }, 20 * 60_000);
      timeout.unref();
      worker.on('message', message => {
        if (message.progress) { job.progress = message.progress; return; }
        if (result || failure) return;
        if (message.error) failure = new Error(message.error); else result = message;
      });
      worker.once('error', error => { failure = error; });
      worker.once('exit', async code => {
        clearTimeout(timeout);
        let published: FleetPackManifest | undefined;
        try {
          if (failure || !result || code !== 0 || this.stopped) throw failure || new Error(`Pack worker exited (${code})`);
          const base = process.env.APP_BASE || '/subwaysForNerds/';
          const manifest: FleetPackManifest = { ...result, id: result.archiveSha256,
            downloadURL: `${base}api/v1/fleet/offline/v2/artifacts/${result.archiveSha256}.jsonl.gz` };
          await rename(destination, join(this.directory, `${manifest.id}.jsonl.gz`));
          await writeFile(join(this.directory, `.building-${jobId}.json`), JSON.stringify(manifest));
          await rename(join(this.directory, `.building-${jobId}.json`), join(this.directory, `${manifest.id}.json`));
          this.retained.set(manifest.id, manifest);
          this.error = '';
          await this.cleanup(manifest.id).catch(error => { this.error = `Pack cleanup failed: ${error}`; });
          published = manifest;
        } catch (error) { job.state = 'unavailable'; job.error = String(error); this.error = job.error; }
        finally {
          await rm(destination, { force: true }).catch(() => {});
          await rm(join(this.directory, `.building-${jobId}.json`), { force: true }).catch(() => {});
          this.active = undefined;
          if (published) { job.manifest = published; job.state = 'ready'; }
          resolve();
        }
      });
    });
    this.active = { key, worker, done };
    return this.publicState(job);
  }

  private publicState(job: PackJob): PackState {
    return { jobId: job.jobId, state: job.state, ...(job.manifest ? { manifest: job.manifest } : {}),
      ...(job.state === 'preparing' && job.progress ? { progress: job.progress } : {}), ...(job.error ? { error: job.error } : {}) };
  }
  status(jobId: string): PackState | undefined {
    const job = this.jobs.get(jobId);
    if (job?.manifest && !this.retained.has(job.manifest.id)) return { jobId, state: 'unavailable', error: 'Fleet pack expired; prepare it again' };
    return job ? this.publicState(job) : undefined;
  }

  async artifact(id: string) {
    if (!hash.test(id)) return;
    const manifest = this.retained.get(id);
    if (!manifest) return;
    try {
      const file = await open(join(this.directory, `${id}.jsonl.gz`), 'r');
      const info = await file.stat();
      if (info.size !== manifest.archiveByteLength) { await file.close(); return; }
      this.leases.set(id, (this.leases.get(id) || 0) + 1);
      let released = false;
      return { file, stat: info, sha256: manifest.archiveSha256, release: () => {
        if (released) return;
        released = true;
        const count = (this.leases.get(id) || 1) - 1;
        if (count) this.leases.set(id, count); else this.leases.delete(id);
      } };
    } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return; throw error; }
  }

  private async reclaimForBuild() {
    const required = (this.options.reserveBytes ?? 2 * 1024 ** 3) +
      (this.options.maximumArtifactBytes ?? maximumCacheBytes) + 16 * 1024 ** 2;
    const free = () => { const disk = statfsSync(this.directory); return disk.bavail * disk.bsize; };
    if (free() >= required) return;
    const candidates = await Promise.all([...this.retained.values()].map(async manifest => ({ manifest,
      info: await stat(join(this.directory, `${manifest.id}.jsonl.gz`)).catch(() => undefined) })));
    candidates.sort((a, b) => (a.info?.mtimeMs || 0) - (b.info?.mtimeMs || 0));
    for (const { manifest } of candidates) {
      if (free() >= required) break;
      if (this.leases.has(manifest.id)) continue;
      await this.remove(manifest);
    }
  }

  private async remove(manifest: FleetPackManifest) {
    this.retained.delete(manifest.id);
    await rm(join(this.directory, `${manifest.id}.jsonl.gz`), { force: true });
    await rm(join(this.directory, `${manifest.id}.json`), { force: true });
  }

  async cleanup(protectedId?: string) {
    const items = await Promise.all([...this.retained.values()].map(async manifest => ({ manifest,
      info: await stat(join(this.directory, `${manifest.id}.jsonl.gz`)).catch(() => undefined) })));
    items.sort((a, b) => (b.info?.mtimeMs || 0) - (a.info?.mtimeMs || 0) || b.manifest.id.localeCompare(a.manifest.id));
    let kept = 0, bytes = 0;
    for (const { manifest, info } of items) {
      if (!info) { this.retained.delete(manifest.id); continue; }
      if (manifest.id === protectedId || this.leases.has(manifest.id) ||
        (kept < 2 && bytes + info.size <= maximumCacheBytes && Date.now() - info.mtimeMs < 24 * hour)) {
        kept++; bytes += info.size; continue;
      }
      await this.remove(manifest);
    }
    for (const [jobId, job] of this.jobs) if (Date.now() - job.createdAt > 24 * hour) this.jobs.delete(jobId);
  }

  async stop() {
    this.stopped = true;
    await this.active?.worker.terminate();
    await this.active?.done;
  }
}
