import { createServer } from '../server/index';
import { createFixtureService, fixtureNow } from './fixture-service';

Date.now = () => fixtureNow * 1000;
const fixture = await createFixtureService();
// Analytics writes beside the temporary fleet database, never into ./state.
process.env.STATE_DIR = fixture.directory;
const app = await createServer(fixture.service, { exemptLoopbackRateLimits: true });
app.addHook('onClose', async () => { await fixture.close(); });
await app.listen({ host: '127.0.0.1', port: Number(process.env.FIXTURE_PORT || 8092) });
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => { void app.close().then(() => process.exit(0)); });
