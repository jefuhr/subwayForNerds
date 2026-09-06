import { Worker } from 'node:worker_threads';
import type { FleetDetail, FleetPage, FleetSnapshot } from '../shared/fleet';
import type { Train } from '../shared/types';
import { currentConsist } from '../shared/consist';
import { locationFor } from './transit';

export function fleetSnapshot(train: Train, now: number): FleetSnapshot | undefined {
  if (!currentConsist(train.consist, now) || now - train.timestamp > 300 || train.assigned === false || ['CANCELED', 'DELETED'].includes(train.relationship || '')) return;
  const positionIndex = train.position?.stopId ? train.stops.findIndex(s => s.id === train.position!.stopId) : -1;
  const next = train.stops.find((s, index) => s.relationship !== 'SKIPPED' &&
    index >= Math.max(0, positionIndex + (train.position?.status === 'STOPPED_AT' ? 1 : 0)) &&
    ((s.arrival ?? s.departure) == null || (s.arrival ?? s.departure)! >= now));
  return { cars: train.consist.cars, namespace: train.feed === 'gtfs-si' ? 'sir' : 'nyct', observation: {
    timestamp: Math.min(train.timestamp, train.consist.updatedAt), locationTimestamp: train.position?.timestamp,
    location: train.position?.stopId ? locationFor(train) : next ? `Next reported stop · ${next.name}` : 'Position unavailable', route: train.route, tripKey: train.key,
    next: next ? { stationId: next.stationId, name: next.name, time: next.arrival ?? next.departure } : undefined,
  } };
}

export class FleetService {
  readonly worker: Worker;
  ready: Promise<unknown>;
  error = '';
  initialized = false;
  private serial = 0;
  private pending = new Map<number, { resolve: (value: any) => void; reject: (reason: Error) => void }>();
  private queued?: { snapshots: FleetSnapshot[]; now: number };
  private writing = false;
  private writeDone: Promise<void> = Promise.resolve();
  private closing = false;
  constructor(file: string) {
    this.worker = new Worker(new URL('./fleet-worker.mjs', import.meta.url), { workerData: { file } });
    this.ready = new Promise((resolve, reject) => this.pending.set(0, { resolve, reject }));
    this.worker.on('message', ({ id, value, error }) => {
      const pending = this.pending.get(id); if (!pending) return;
      this.pending.delete(id);
      if (error) { this.error = error; pending.reject(new Error(error)); }
      else pending.resolve(value);
    });
    const fail = (error: Error) => { this.error = error.message; for (const p of this.pending.values()) p.reject(error); this.pending.clear(); };
    this.worker.on('error', fail);
    this.worker.on('exit', () => fail(new Error('Fleet database worker is unavailable')));
    // Initialization may finish before the background startup task awaits it.
    void this.ready.then(() => { this.initialized = true; }).catch(() => {});
  }
  async call<T>(action: string, ...args: unknown[]): Promise<T> {
    await this.ready;
    if (this.error && this.worker.threadId === -1) throw new Error(this.error);
    const id = ++this.serial;
    return new Promise((resolve, reject) => { this.pending.set(id, { resolve, reject }); this.worker.postMessage({ id, action, args }); });
  }
  list(query: Record<string, string>, now: number) { return this.call<FleetPage>('list', query, now); }
  detail(id: string, now: number) { return this.call<FleetDetail | undefined>('detail', id, now); }
  observe(snapshots: FleetSnapshot[], now: number) {
    if (this.closing) return;
    this.queued = { snapshots, now };
    if (this.writing) return;
    this.writing = true;
    this.writeDone = (async () => {
      try { while (this.queued) { const batch = this.queued; this.queued = undefined; await this.call('observe', batch.snapshots, batch.now); } }
      catch (e) { this.error = String(e); }
      finally { this.writing = false; }
    })();
  }
  async close() { this.closing = true; try { await this.writeDone; await this.call('close'); } finally { await this.worker.terminate(); } }
}
