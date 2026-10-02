import { Worker } from 'node:worker_threads';
import { randomUUID } from 'node:crypto';
import { mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { FleetOfflineManifest } from '../shared/offline';

const hour = 3600000;
const artifactName = /^[a-f0-9]{64}\.sqlite(?:\.gz)?$/;
const hash = /^[a-f0-9]{64}$/;
type SnapshotResult = Omit<FleetOfflineManifest, 'id' | 'downloadURL'>;
interface ExportOptions {
  /** Bytes that must remain free, excluding bounded SQLite/stream buffers. */
  reserveBytes?: number;
  /** Deterministic worker-space readings for failure-path tests only. */
  availableBytesForTests?: number[];
}
const filename = (value: FleetOfflineManifest) => `${value.id}.sqlite${value.compression === 'gzip' ? '.gz' : ''}`;

/** Export work never occupies the departure event loop or the live fleet worker. */
export class FleetOfflineService {
  manifest?: FleetOfflineManifest;
  error = '';
  private pending?: Promise<FleetOfflineManifest>;
  private worker?: Worker;
  private timer?: ReturnType<typeof setTimeout>;
  private stopped = false;
  constructor(readonly source: string, readonly directory: string, private options: ExportOptions = {}) {}

  async start() {
    await this.restore();
    const run = async () => {
      if (this.stopped) return;
      try { await this.rebuild(); } catch (error) { this.error = String(error); }
      if (!this.stopped) { this.timer = setTimeout(() => { void run(); }, hour); this.timer.unref(); }
    };
    await run();
  }

  async restore() {
    await mkdir(this.directory, { recursive: true });
    try {
      const value = JSON.parse(await readFile(join(this.directory, 'manifest.json'), 'utf8')) as FleetOfflineManifest;
      if (value.schemaVersion !== 1 || !hash.test(value.id) || value.id !== value.sha256 ||
        !Number.isSafeInteger(value.byteLength) || value.byteLength <= 0 || !Number.isFinite(value.generatedAt) ||
        (value.compression !== undefined && (value.compression !== 'gzip' || !hash.test(value.compressedSha256 || '') ||
          !Number.isSafeInteger(value.compressedByteLength) || value.compressedByteLength! <= 0))) throw new Error('Invalid saved fleet manifest');
      if ((await stat(join(this.directory, filename(value)))).size !== (value.compressedByteLength ?? value.byteLength)) throw new Error('Incomplete saved fleet snapshot');
      this.manifest = value;
    } catch { /* An absent or interrupted publication is rebuilt independently. */ }
    for (const name of await readdir(this.directory)) if (/^\.(?:building-|manifest-)/.test(name)) await rm(join(this.directory, name), { force: true });
    await this.cleanup();
  }

  rebuild(generatedAt?: number): Promise<FleetOfflineManifest> {
    if (this.stopped) return Promise.reject(new Error('Fleet snapshot service stopped'));
    if (!this.pending) this.pending = this.build(generatedAt).finally(() => { this.pending = undefined; });
    return this.pending;
  }

  private async build(generatedAt?: number) {
    await mkdir(this.directory, { recursive: true });
    const token = randomUUID(), temporary = join(this.directory, `.building-${token}.sqlite`);
    const temporaryManifest = join(this.directory, `.manifest-${token}.json`);
    const removeStaging = () => Promise.all([temporary, `${temporary}-journal`, `${temporary}.gz`, temporaryManifest].map(file => rm(file, { force: true }).catch(() => {})));
    const runWorker = () => new Promise<SnapshotResult>((resolve, reject) => {
      const worker = this.worker = new Worker(new URL('./fleet-offline-worker.mjs', import.meta.url), {
        workerData: { source: this.source, destination: temporary, generatedAt, ...this.options },
      });
      let result: SnapshotResult | undefined, failure: Error | undefined;
      // Wait for exit before removing staging, including on a low-space error.
      worker.once('message', message => { if (message.error) failure = Object.assign(new Error(message.error), { code: message.code }); else result = message; });
      worker.once('error', error => { failure = error; });
      worker.once('exit', code => { failure ? reject(failure) : result ? resolve(result) : reject(new Error(`Fleet export worker exited before completion (${code})`)); });
    });
    try {
      if (this.stopped) throw new Error('Fleet snapshot service stopped');
      let result: SnapshotResult;
      try { result = await runWorker(); }
      catch (error) {
        // Reclaim previous generations only when space is actually needed. The
        // current publication remains available throughout either attempt.
        if ((error as NodeJS.ErrnoException).code !== 'ENOSPC' || this.stopped) throw error;
        await removeStaging();
        const removed = await this.cleanup(true);
        if (!removed) throw error;
        result = await runWorker();
      }
      if (this.stopped) throw new Error('Fleet snapshot service stopped');
      const base = process.env.APP_BASE || '/subwaysForNerds/';
      const manifest: FleetOfflineManifest = { ...result, id: result.sha256,
        downloadURL: `${base}api/v1/fleet/offline/snapshots/${result.sha256}.sqlite.gz` };
      await rename(`${temporary}.gz`, join(this.directory, filename(manifest)));
      await writeFile(temporaryManifest, JSON.stringify(manifest));
      // Retain immutable metadata for the previous artifact's gzip ETag.
      await rename(temporaryManifest, join(this.directory, `${manifest.id}.json`));
      await writeFile(temporaryManifest, JSON.stringify(manifest));
      await rename(temporaryManifest, join(this.directory, 'manifest.json'));
      this.manifest = manifest; this.error = '';
      await this.cleanup().catch(() => { /* A cleanup failure cannot undo a valid publication. */ });
      return manifest;
    } catch (error) { this.error = String(error); throw error; }
    finally { this.worker = undefined; await removeStaging(); }
  }

  async cleanup(reclaimSpace = false) {
    const cutoff = Date.now() - 24 * hour;
    const candidates = await Promise.all((await readdir(this.directory)).filter(name => artifactName.test(name)).map(async name => ({ name, info: await stat(join(this.directory, name)) })));
    candidates.sort((a, b) => b.info.mtimeMs - a.info.mtimeMs || a.name.localeCompare(b.name));
    let kept = this.manifest ? 1 : 0, removed = 0;
    for (const { name, info } of candidates) {
      if (this.manifest && name === filename(this.manifest)) continue;
      if (!reclaimSpace && info.mtimeMs >= cutoff && kept < 2) { kept++; continue; }
      await rm(join(this.directory, name), { force: true });
      const id = name.slice(0, 64);
      // A legacy raw file can share the same identity with its gzip version.
      if (this.manifest?.id !== id && !await stat(join(this.directory, `${id}.sqlite.gz`)).catch(() => undefined)) {
        await rm(join(this.directory, `${id}.json`), { force: true });
      }
      removed++;
    }
    return removed;
  }

  async artifact(id: string, compressed = false) {
    if (!hash.test(id)) return;
    try {
      const file = await open(join(this.directory, `${id}.sqlite${compressed ? '.gz' : ''}`), 'r');
      try {
        const info = await file.stat();
        const metadata: FleetOfflineManifest | undefined = compressed ? (this.manifest?.id === id && this.manifest.compression === 'gzip' ? this.manifest : JSON.parse(await readFile(join(this.directory, `${id}.json`), 'utf8'))) : undefined;
        if (compressed && (metadata?.id !== id || metadata.sha256 !== id || metadata.compression !== 'gzip' ||
          !hash.test(metadata.compressedSha256 || '') || metadata.compressedByteLength !== info.size)) throw new Error('Invalid compressed snapshot metadata');
        return { file, stat: info, sha256: metadata?.compressedSha256 ?? id };
      } catch (error) { await file.close(); throw error; }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return;
      throw error;
    }
  }

  async stop() {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    await this.worker?.terminate();
    await this.pending?.catch(() => {});
  }
}
