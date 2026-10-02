import { createServer } from '../server/index';
import { createFixtureService, fixtureNow } from './fixture-service';

Date.now = () => fixtureNow * 1000;
const fixture = await createFixtureService();
const app = await createServer(fixture.service);
app.addHook('onClose', async () => { await fixture.close(); });
await app.listen({ host: '127.0.0.1', port: Number(process.env.FIXTURE_PORT || 8092) });
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => { void app.close().then(() => process.exit(0)); });
