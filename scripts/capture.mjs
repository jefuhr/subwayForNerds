import { chromium } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
await mkdir('artifacts', { recursive: true });
const browser = await chromium.launch({ headless: true });
for (const [name, viewport] of [['desktop', { width: 1440, height: 1100 }], ['mobile', { width: 390, height: 844 }]]) {
  const page = await browser.newPage({ viewport, deviceScaleFactor: 1 });
  page.on('pageerror', e => console.log('PAGE ERROR', e.message));
  await page.goto('http://127.0.0.1:8091/subwaysForNerds/?station=602');
  await page.locator('.train-row').first().waitFor();
  await page.screenshot({ path: `artifacts/${name}.png`, fullPage: false });
  console.log(name, await page.evaluate(() => ({ overflow: document.documentElement.scrollWidth > innerWidth, title: document.title, trains: document.querySelectorAll('.train-row').length })));
  await page.close();
}
await browser.close();
