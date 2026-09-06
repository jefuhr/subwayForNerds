import Fastify from 'fastify';
import compress from '@fastify/compress';
import staticFiles from '@fastify/static';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { TransitService } from './service';

export async function createServer(service = new TransitService({ fixtureDir: process.env.FIXTURE_DIR })) {
  const app = Fastify({ logger: process.env.NODE_ENV === 'production' });
  const base = process.env.APP_BASE || '/subwaysForNerds/';
  if (!/^\/(?:[A-Za-z0-9_-]+\/)*$/.test(base)) throw new Error('APP_BASE must be an absolute path ending in /');
  await app.register(compress);
  const api = base + 'api/v1';
  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('Referrer-Policy', 'strict-origin-when-cross-origin');
    return payload;
  });
  const send = (req: any, reply: any, value: unknown) => {
    const json = JSON.stringify(value), etag = '"' + createHash('sha1').update(json).digest('hex') + '"';
    reply.header('ETag', etag).header('Cache-Control', 'no-cache').type('application/json');
    if (req.headers['if-none-match'] === etag) return reply.code(304).send();
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
  app.get(api + '/health', () => ({ status: [...service.slots.values()].some(s => s.state.timestamp && !s.state.error) ? 'ok' : 'degraded', feeds: [...service.slots.values()].map(s => s.state), stationCount: service.catalog.length }));
  app.get('/healthz', () => ({ status: 'ok' }));
  if (base !== '/') app.get(base.slice(0, -1), (_req, reply) => reply.redirect(base));
  if (existsSync(resolve('dist'))) {
    await app.register(staticFiles, { root: resolve('dist'), prefix: base, index: ['index.html'],
      setHeaders: (res, file) => { res.setHeader('Cache-Control', file.includes('/assets/') ? 'public, max-age=31536000, immutable' : 'no-cache'); } });
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
