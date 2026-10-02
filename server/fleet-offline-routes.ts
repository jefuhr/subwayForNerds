import type { FastifyInstance } from 'fastify';
import type { TransitService } from './service';

function byteRange(header: string, size: number) {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match || (!match[1] && !match[2])) return;
  const start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
  const end = match[1] && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
  if (![start, end, ...(match[2] ? [Number(match[2])] : [])].every(Number.isSafeInteger) || start < 0 || start >= size || end < start || (!match[1] && Number(match[2]) === 0)) return;
  return { start, end };
}

export function registerFleetOfflineRoutes(app: FastifyInstance, service: TransitService, api: string) {
  app.get(api + '/fleet/offline/manifest', (_req, reply) => {
    const manifest = service.offline?.manifest;
    reply.header('Cache-Control', 'no-cache');
    if (!manifest) return reply.code(503).header('Retry-After', '60').send({ error: 'Offline fleet snapshot is preparing or unavailable; live departures are unaffected' });
    return { ...manifest, downloadURL: `${api}/fleet/offline/snapshots/${manifest.id}.sqlite${manifest.compression === 'gzip' ? '.gz' : ''}` };
  });
  for (const compressed of [true, false]) app.get<{ Params: { id: string } }>(api + `/fleet/offline/snapshots/:id.sqlite${compressed ? '.gz' : ''}`, { config: { compress: false } }, async (req, reply) => {
    const artifact = await service.offline?.artifact(req.params.id, compressed);
    if (!artifact) return reply.code(404).send({ error: 'Snapshot no longer available; refresh the offline fleet manifest' });
    const { file, stat } = artifact, etag = `"${artifact.sha256}"`;
    reply.header('ETag', etag).header('Cache-Control', 'public, max-age=31536000, immutable')
      .header('Accept-Ranges', 'bytes').header('Last-Modified', stat.mtime.toUTCString())
      .type(compressed ? 'application/gzip' : 'application/vnd.sqlite3');
    const matches = req.headers['if-none-match']?.split(',').some(value => value.trim() === etag || value.trim() === '*');
    if (matches) { await file.close(); return reply.code(304).send(); }
    const ifRange = String(req.headers['if-range'] || '');
    const useRange = !ifRange || ifRange === etag || (!ifRange.startsWith('"') && Date.parse(ifRange) >= Math.floor(stat.mtimeMs / 1000) * 1000);
    let start = 0, end = stat.size - 1;
    if (req.headers.range && useRange) {
      const range = byteRange(req.headers.range, stat.size);
      if (!range) { await file.close(); return reply.code(416).header('Content-Range', `bytes */${stat.size}`).send(); }
      ({ start, end } = range);
      reply.code(206).header('Content-Range', `bytes ${start}-${end}/${stat.size}`);
    }
    reply.header('Content-Length', end - start + 1);
    return reply.send(file.createReadStream({ start, end, autoClose: true }));
  });
}
