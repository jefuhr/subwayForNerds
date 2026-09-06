import { performance } from 'node:perf_hooks';
import { mkdir, writeFile } from 'node:fs/promises';
import { chromium } from '@playwright/test';

const origin = process.env.BENCH_URL || 'http://127.0.0.1:8091/subwaysForNerds/';
const url = origin + 'api/v1/stations/602/board';
await fetch(url).then(r => r.arrayBuffer());
const timings = [];
await Promise.all(Array.from({ length: 50 }, async () => {
  for (let i = 0; i < 10; i++) {
    const start = performance.now();
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    await response.arrayBuffer(); timings.push(performance.now() - start);
  }
}));
timings.sort((a, b) => a - b);
const browser = await chromium.launch({ headless: true });
const samples = [];
for (let i = 0; i < 5; i++) {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Network.enable');
  await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 70, downloadThroughput: 1.25 * 1024 * 1024, uploadThroughput: 512 * 1024 });
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
  await page.goto(origin + '?station=602', { waitUntil: 'commit' });
  await page.locator('.train-row').first().waitFor();
  const cold = await page.evaluate(() => performance.getEntriesByName('sfn-board-visible')[0]?.startTime || performance.now());
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload({ waitUntil: 'commit' });
  await page.locator('.train-row').first().waitFor();
  const repeat = await page.evaluate(() => performance.getEntriesByName('sfn-board-visible')[0]?.startTime || performance.now());
  samples.push({ coldBoardMs: Math.round(cold), repeatBoardMs: Math.round(repeat) });
  await context.close();
}
await browser.close();
const result = { measuredAt: new Date().toISOString(), requests: timings.length, concurrency: 50,
  apiP50Ms: Math.round(timings[Math.floor(timings.length * .5)]), apiP95Ms: Math.round(timings[Math.floor(timings.length * .95)]),
  network: '70ms latency, 10Mbps down, 4Mbps up, 4x CPU throttle; localhost server', samples };
await mkdir('artifacts', { recursive: true });
await writeFile('artifacts/performance.json', JSON.stringify(result, null, 2));
console.log(JSON.stringify(result, null, 2));
if (result.apiP95Ms > 100 || samples.some(s => s.coldBoardMs > 1500 || s.repeatBoardMs > 200)) process.exitCode = 1;
