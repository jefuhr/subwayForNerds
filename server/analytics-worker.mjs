import { parentPort, workerData } from 'node:worker_threads';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { AnalyticsStore } from './analytics-store.mjs';
try {
  mkdirSync(dirname(workerData.file), { recursive: true });
  const store = new AnalyticsStore(workerData.file);
  const timer = setInterval(() => { try { store.cleanup(Date.now()); } catch { /* retry next interval */ } }, 3600000);
  parentPort.postMessage({ id: 0, value: true });
  parentPort.on('message', ({ id, action, args }) => {
    try {
      if (!['record', 'stats', 'close'].includes(action)) throw new Error('Unknown operation');
      const value = store[action](...args); parentPort.postMessage({ id, value });
      if (action === 'close') { clearInterval(timer); parentPort.close(); }
    } catch { parentPort.postMessage({ id, error: 'Analytics database unavailable' }); }
  });
} catch { parentPort.postMessage({ id: 0, error: 'Analytics database unavailable' }); parentPort.close(); }
