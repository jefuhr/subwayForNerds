import { readFile } from 'node:fs/promises';
import { chromium } from '@playwright/test';
const svg = await readFile('public/icon.svg', 'utf8');
const browser = await chromium.launch({ headless: true });
for (const size of [192, 512]) {
  const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
  await page.setContent(`<style>body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${svg}`);
  await page.screenshot({ path: `public/icon-${size}.png`, omitBackground: true });
  await page.close();
}
await browser.close();
