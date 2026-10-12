import type { FastifyInstance } from 'fastify';
import rateLimit from '@fastify/rate-limit';
import type { TransitService } from './service';
import type { FleetPackSelection } from '../shared/offline';
import { byteRange } from './fleet-offline-routes';

export async function registerFleetPackRoutes(app: FastifyInstance, service: TransitService, api: string) {
  await app.register(async scoped => {
    await scoped.register(rateLimit, { global: false, max: 5, timeWindow: 60_000 });
    scoped.post<{ Body: FleetPackSelection }>(api + '/fleet/offline/v2/packs', {
      config: { rateLimit: { max: 5, timeWindow: 60_000 } }, bodyLimit: 4096,
    }, async (req, reply) => {
      if (!service.packs?.ready) return reply.code(503).header('Retry-After', '60').send({ state: 'unavailable', error: 'Offline fleet packs are starting or unavailable' });
      try {
        const state = await service.packs.request(req.body);
        reply.header('Cache-Control', 'no-store');
        if (state.state === 'preparing') return reply.code(202).header('Retry-After', '3').send(state);
        if (!state.jobId) return reply.code(429).header('Retry-After', '10').send(state);
        if (state.state === 'unavailable') return reply.code(503).header('Retry-After', '60').send(state);
        return state;
      } catch (error) {
        if (/Invalid fleet pack selection|Unknown fleet pack filter/.test(String(error))) return reply.code(400).send({ error: String(error) });
        return reply.code(503).header('Retry-After', '60').send({ state: 'unavailable', error: 'Fleet pack preparation is unavailable' });
      }
    });
    scoped.get<{ Params: { jobId: string } }>(api + '/fleet/offline/v2/packs/:jobId', (req, reply) => {
      const state = service.packs?.status(req.params.jobId);
      reply.header('Cache-Control', 'no-store');
      if (!state) return reply.code(404).send({ error: 'Fleet pack request expired; prepare it again' });
      if (state.state === 'preparing') return reply.code(202).header('Retry-After', '3').send(state);
      if (state.state === 'unavailable') return reply.code(503).header('Retry-After', '60').send(state);
      return state;
    });
    scoped.get<{ Params: { id: string } }>(api + '/fleet/offline/v2/artifacts/:id.jsonl.gz', { config: { compress: false } }, async (req, reply) => {
      const item = await service.packs?.artifact(req.params.id);
      if (!item) return reply.code(404).send({ error: 'Fleet pack expired; prepare it again' });
      const { file, stat } = item, etag = `"${item.sha256}"`;
      reply.header('ETag', etag).header('Cache-Control', 'public, max-age=31536000, immutable')
        .header('Accept-Ranges', 'bytes').header('Last-Modified', stat.mtime.toUTCString()).type('application/gzip');
      const matches = req.headers['if-none-match']?.split(',').some(value => value.trim() === etag || value.trim() === '*');
      if (matches) { await file.close(); item.release(); return reply.code(304).send(); }
      const ifRange = String(req.headers['if-range'] || '');
      const useRange = !ifRange || ifRange === etag || (!ifRange.startsWith('"') && Date.parse(ifRange) >= Math.floor(stat.mtimeMs / 1000) * 1000);
      let start = 0, end = stat.size - 1;
      if (req.headers.range && useRange) {
        const range = byteRange(req.headers.range, stat.size);
        if (!range) { await file.close(); item.release(); return reply.code(416).header('Content-Range', `bytes */${stat.size}`).send(); }
        ({ start, end } = range);
        reply.code(206).header('Content-Range', `bytes ${start}-${end}/${stat.size}`);
      }
      reply.header('Content-Length', end - start + 1);
      const stream = file.createReadStream({ start, end, autoClose: true });
      stream.once('close', item.release);
      return reply.send(stream);
    });
  });
}
