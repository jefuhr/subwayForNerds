import Fastify from 'fastify';
import compress from '@fastify/compress';
import staticFiles from '@fastify/static';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { pathToFileURL } from 'node:url';
import { TransitService } from './service';
import { nowSeconds } from './transit';
import { transfers } from './transfers';

export async function createServer(service = new TransitService({ fixtureDir: process.env.FIXTURE_DIR })) {
  const app = Fastify({ logger: process.env.NODE_ENV === 'production' });
  const base = process.env.APP_BASE || '/subwaysForNerds/';
  if (!/^\/(?:[A-Za-z0-9_-]+\/)*$/.test(base)) throw new Error('APP_BASE must be an absolute path ending in /');
  await app.register(compress);
  const api = base + 'api/v1';
  const encoded = new WeakMap<object, { json: string; gzip: Buffer; etag: string }>();
  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('Referrer-Policy', 'strict-origin-when-cross-origin');
    return payload;
  });
  const send = (req: any, reply: any, value: unknown) => {
    let cached = typeof value === 'object' && value !== null ? encoded.get(value) : undefined;
    if (!cached) {
      const json = JSON.stringify(value), etag = '"' + createHash('sha1').update(json).digest('hex') + '"';
      cached = { json, gzip: gzipSync(json, { level: 4 }), etag };
      if (typeof value === 'object' && value !== null) encoded.set(value, cached);
    }
    const { json, gzip, etag } = cached;
    reply.header('ETag', etag).header('Cache-Control', 'no-cache').type('application/json');
    reply.header('Vary', 'Accept-Encoding');
    if (req.headers['if-none-match'] === etag) return reply.code(304).send();
    if ((req.headers['accept-encoding'] || '').split(',').some((s: string) => /^\s*gzip\s*(?:;\s*q=(?!0(?:\.0*)?\s*$)[\d.]+)?\s*$/.test(s))) return reply.header('Content-Encoding', 'gzip').send(gzip);
    return reply.send(json);
  };
  app.get(api + '/stations', (req, reply) => send(req, reply, service.catalog));
  app.get<{ Params: { id: string } }>(api + '/stations/:id/board', (req, reply) => {
    const board = service.boards.get(req.params.id);
    return board ? send(req, reply, board) : reply.code(404).send({ error: 'Unknown station' });
  });
  app.get<{ Params: { id: string } }>(api + '/stations/:id/context', (req, reply) => {
    const context = service.context(req.params.id);
    return context ? send(req, reply, context) : reply.code(404).send({ error: 'Unknown station' });
  });
  app.get<{ Querystring: { key?: string } }>(api + '/trips', (req, reply) => {
    const detail = service.details.get(req.query.key || '');
    return detail ? send(req, reply, detail) : reply.code(404).send({ error: 'This trip is no longer in the current feed' });
  });
  app.get<{ Querystring: { key?: string; stopId?: string; sequence?: string } }>(api + '/trips/transfers', (req, reply) => {
    const { key, stopId, sequence } = req.query;
    if (!key || !stopId || (sequence != null && !/^\d+$/.test(sequence))) return reply.code(400).send({ error: 'Trip and valid stop identity required' });
    return send(req, reply, transfers(service.details.get(key)?.train, service.boards, stopId, sequence == null ? undefined : Number(sequence), nowSeconds()));
  });
  app.get<{ Querystring: Record<string, string> }>(api + '/fleet', async (req, reply) => {
    if (!service.fleet) return reply.code(503).send({ error: 'Fleet database is starting or unavailable' });
    if (Object.values(req.query).some(v => typeof v !== 'string' || v.length > 200) || (req.query.page && !/^[1-9]\d{0,5}$/.test(req.query.page))) return reply.code(400).send({ error: 'Invalid fleet filter' });
    try { return send(req, reply, await service.fleet.list(req.query, nowSeconds())); }
    catch { return reply.code(503).send({ error: 'Fleet database unavailable; departures are unaffected' }); }
  });
  for (const kind of ['cars', 'consists']) app.get<{ Params: { id: string } }>(api + '/fleet/' + kind + '/:id', async (req, reply) => {
    if (!service.fleet) return reply.code(503).send({ error: 'Fleet database unavailable' });
    try { const data = await service.fleet.detail(req.params.id, nowSeconds()); return data ? send(req, reply, data) : reply.code(404).send({ error: 'Car or consist has not been recorded' }); }
    catch { return reply.code(503).send({ error: 'Fleet database unavailable; departures are unaffected' }); }
  });
  app.get(api + '/fleet/health', () => ({ available: !!service.fleet?.initialized && !service.fleet.error, error: service.fleet?.error || null }));
  app.get(api + '/health', () => ({ status: [...service.slots.values()].every(s => s.state.timestamp && nowSeconds() - s.state.timestamp <= 90 && !s.state.error) ? 'ok' : 'degraded', feeds: [...service.slots.values()].map(s => ({ ...s.state, age: s.state.timestamp ? nowSeconds() - s.state.timestamp : null })), stationCount: service.catalog.length }));
  app.get('/healthz', () => ({ status: 'ok' }));
  if (base !== '/') app.get(base.slice(0, -1), (_req, reply) => reply.redirect(base));
  if (existsSync(resolve('dist'))) {
    await app.register(staticFiles, { root: resolve('dist'), prefix: base, index: ['index.html'],
      setHeaders: (reply, file) => { reply.header('Cache-Control', file.includes('/assets/') ? 'public, max-age=31536000, immutable' : 'no-cache'); } });
  }
  app.addHook('onClose', () => service.stop());
  return app;
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const service = new TransitService({ fixtureDir: process.env.FIXTURE_DIR });
  // Empty station boards are available before any upstream request completes.
  service.refreshBoards();
  const app = await createServer(service);
  await app.listen({ host: process.env.HOST || '127.0.0.1', port: Number(process.env.PORT || 8091) });
  void service.start();
  for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => { void app.close().then(() => process.exit(0)); });
}
