import { readFileSync } from 'node:fs';
import { createServer } from '../server/index';
import { TransitService } from '../server/service';
import { FEED_ROUTES } from '../server/transit';
import { decode } from '../server/decode';

const service = new TransitService();
for (const id of [...Object.keys(FEED_ROUTES), 'subway-alerts']) {
  const raw = decode(readFileSync(new URL(`fixtures/${id}.pb`, import.meta.url)), id === 'subway-alerts');
  service.accept(id, raw, raw.header.timestamp);
}
const app = await createServer(service);
await app.listen({ host: '127.0.0.1', port: 8092 });
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => { void app.close().then(() => process.exit(0)); });
