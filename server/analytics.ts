import { Worker } from 'node:worker_threads';
import { createHash, randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { eventNames, type AnalyticsEvent, type Stats } from '../shared/analytics';
export class AnalyticsService {
  worker: Worker;
  pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  serial = 0;
  ready: Promise<unknown>;
  failed = false;
  constructor(file: string) {
    this.worker = new Worker(new URL('./analytics-worker.mjs', import.meta.url), { workerData: { file } });
    this.ready = new Promise((resolve, reject) => this.pending.set(0, { resolve, reject }));
    this.worker.on('message', ({ id, value, error }) => { const p = this.pending.get(id); this.pending.delete(id); if (error) p?.reject(new Error(error)); else p?.resolve(value); });
    const fail = () => { this.failed = true; for (const p of this.pending.values()) p.reject(new Error('Analytics unavailable')); this.pending.clear(); };
    this.worker.on('error', fail); this.worker.on('exit', fail);
    void this.ready.catch(() => {});
  }
  async call<T>(action: string, ...args: unknown[]): Promise<T> {
    await this.ready;
    if (this.failed || this.pending.size >= 32) throw new Error('Analytics unavailable');
    const id = ++this.serial;
    return new Promise((resolve, reject) => { this.pending.set(id, { resolve, reject }); this.worker.postMessage({ id, action, args }); });
  }
  async close() { try { await this.call('close'); } catch { /* failed worker */ } finally { await this.worker.terminate(); } }
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function validEvent(e: any, stations: Set<string>): e is AnalyticsEvent {
  return e && typeof e === 'object' && Object.keys(e).every(k => ['id', 'browser', 'session', 'name', 'station', 'device', 'referrer'].includes(k)) &&
    [e.id, e.browser, e.session].every(v => typeof v === 'string' && uuid.test(v)) && eventNames.includes(e.name) &&
    ['phone', 'tablet', 'desktop'].includes(e.device) && typeof e.referrer === 'string' && e.referrer.length <= 253 && /^(?:[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?)?$/i.test(e.referrer) &&
    (e.station === undefined || stations.has(e.station)) && (!['station_view', 'favorite_add', 'favorite_remove', 'direction', 'line', 'reset', 'train_open'].includes(e.name) || stations.has(e.station));
}
export function registerAnalytics(app: FastifyInstance, api: string, stations: { id: string; name: string }[]) {
  const service = new AnalyticsService(resolve(process.env.STATE_DIR || 'state', 'analytics.sqlite'));
  const ids = new Set(stations.map(s => s.id));
  const salt = randomUUID(), rates = new Map<string, { count: number; until: number }>();
  let global = { count: 0, until: 0 };
  app.post(api + '/analytics/events', { bodyLimit: 16384, logLevel: 'silent' }, async (req, reply) => {
    const now = Date.now();
    for (const [key, value] of rates) if (value.until <= now) rates.delete(key);
    if (global.until <= now) global = { count: 0, until: now + 60000 };
    const key = createHash('sha256').update(salt + req.ip).digest('hex');
    const rate = rates.get(key) || { count: 0, until: now + 60000 };
    if (++global.count > 1000 || ++rate.count > 60 || (!rates.has(key) && rates.size >= 5000)) return reply.code(429).header('Retry-After', '60').send({ error: 'Try later' });
    rates.set(key, rate);
    const body = req.body as any;
    if (!body || Object.keys(body).some(k => k !== 'events') || !Array.isArray(body.events) || !body.events.length || body.events.length > 20 || !body.events.every((e: unknown) => validEvent(e, ids))) return reply.code(400).send({ error: 'Invalid events' });
    try { await service.call('record', body.events); return reply.code(204).send(); }
    catch { return reply.code(503).send({ error: 'Analytics unavailable' }); }
  });
  app.get<{ Querystring: { range?: string } }>(api + '/stats', async (req, reply) => {
    const range = req.query.range || '30d';
    if (!['today', '7d', '30d', '365d'].includes(range)) return reply.code(400).send({ error: 'Invalid range' });
    try {
      const result = await service.call<Stats>('stats', range);
      result.stations = result.stations.map(row => ({ ...row, label: stations.find(s => s.id === row.label)?.name || row.label }));
      return reply.header('Cache-Control', 'no-store').send(result);
    } catch { return reply.code(503).send({ error: 'Statistics unavailable' }); }
  });
  app.addHook('onClose', () => service.close());
}
