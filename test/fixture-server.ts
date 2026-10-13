import { createServer as createHttpServer, request as httpRequest } from 'node:http';
import { createServer } from '../server/index';
import { createFixtureService, fixtureNow } from './fixture-service';

Date.now = () => fixtureNow * 1000;
const fixture = await createFixtureService();
if (process.env.FIXTURE_NJT === '1') {
  const { installNjtUIFixture } = await import('./njt-ui-fixture');
  installNjtUIFixture(fixture.service);
}
// Analytics writes beside the temporary fleet database, never into ./state.
process.env.STATE_DIR = fixture.directory;
const app = await createServer(fixture.service, { exemptLoopbackRateLimits: true });
app.addHook('onClose', async () => { await fixture.close(); });
const port = Number(process.env.FIXTURE_PORT || 8092);
// The same API on a second port with every response body spread over three seconds,
// so UI tests can watch loading progress. Headers, ranges and status pass through.
const slowPort = Number(process.env.FIXTURE_SLOW_PORT || 0);
if (slowPort) {
  const proxy = createHttpServer((req, res) => {
    const upstream = httpRequest({ host: '127.0.0.1', port, path: req.url, method: req.method, headers: req.headers }, async response => {
      response.on('error', error => res.destroy(error));
      res.writeHead(response.statusCode ?? 502, response.headers);
      const chunks: Buffer[] = [];
      for await (const chunk of response) chunks.push(chunk);
      const body = Buffer.concat(chunks), pieces = Math.min(30, body.length);
      for (let index = 0; index < pieces && !res.destroyed; index++) {
        res.write(body.subarray(Math.floor(index * body.length / pieces), Math.floor((index + 1) * body.length / pieces)));
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      res.end();
    });
    upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
    req.pipe(upstream);
  });
  app.addHook('onClose', async () => { proxy.close(); });
  await new Promise<void>(resolve => proxy.listen(slowPort, '127.0.0.1', resolve));
}
await app.listen({ host: '127.0.0.1', port });
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => { void app.close().then(() => process.exit(0)); });
