import { parentPort, workerData } from 'node:worker_threads';
import { mkdir, readFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { FleetStore } from './fleet-store.mjs';

try {
  await mkdir(dirname(workerData.file), { recursive: true });
  const store = new FleetStore(workerData.file);
  if (!store.db.prepare("SELECT data FROM meta WHERE key='roster'").get()) {
    const seed = JSON.parse(gunzipSync(Buffer.from(await readFile(new URL('../data/fleet-roster.base64', import.meta.url), 'utf8'), 'base64')).toString());
    store.importRoster(seed.rows, seed.date);
  }
  store.importSupplement(JSON.parse(await readFile(new URL('../data/fleet-supplement.json', import.meta.url), 'utf8')));
  parentPort.postMessage({ id: 0, value: true });
  parentPort.on('message', ({ id, action, args }) => {
    try {
      if (!['list', 'detail', 'observe', 'importRoster', 'cleanup', 'backup', 'close'].includes(action)) throw new Error('Unknown fleet operation');
      const value = store[action](...args);
      parentPort.postMessage({ id, value });
      if (action === 'close') parentPort.close();
    } catch (error) { parentPort.postMessage({ id, error: String(error) }); }
  });
} catch (error) { parentPort.postMessage({ id: 0, error: String(error) }); parentPort.close(); }
