import { test, expect } from '@playwright/test';

test('preloads all favorites with bounded concurrency, deduplicates selection, and pauses offline', async ({ page, context }) => {
  const stations = await (await page.request.get('api/v1/stations')).json();
  const ids: string[] = ['602', ...stations.map((s: any) => s.id).filter((id: string) => id !== '602').slice(0, 11)];
  await page.addInitScript(ids => { localStorage.setItem('sfn:favorites', JSON.stringify(ids)); }, ids);
  const counts = new Map<string, number>(); let active = 0, maximum = 0;
  await page.route('**/api/v1/stations/*/board', async route => {
    const id = route.request().url().split('/').at(-2)!;
    counts.set(id, (counts.get(id) || 0) + 1); maximum = Math.max(maximum, ++active);
    await new Promise(resolve => setTimeout(resolve, 150));
    try { await route.continue(); } finally { active--; }
  });
  await page.goto('./?station=602');
  await expect.poll(() => counts.size).toBe(ids.length);
  expect(maximum).toBeLessThanOrEqual(3);
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('sfn:cachedStations') || '[]').length)).toBe(ids.length);
  await context.setOffline(true);
  await page.evaluate(id => { history.pushState({}, '', '?station=' + id); dispatchEvent(new PopStateEvent('popstate')); }, ids[10]);
  await expect(page.locator('h1')).toHaveText(stations.find((s: any) => s.id === ids[10]).name);
  await expect(page.getByText('CACHED BOARD', { exact: true })).toBeVisible();
  expect(counts.get(ids[10])).toBe(1);
  await context.setOffline(false);
});

test('station preferences migrate once, survive navigation and reload, and do not count restoration as actions', async ({ page }) => {
  await page.addInitScript(() => {
    if (!localStorage.getItem('seeded')) { localStorage.setItem('seeded', 'true'); localStorage.setItem('sfn:station', '602'); localStorage.setItem('sfn:direction', '"NORTH"'); localStorage.setItem('sfn:routes', '["4"]'); }
  });
  const events: any[] = [];
  await page.route('**/api/v1/analytics/events', async route => { events.push(...route.request().postDataJSON().events); await route.fulfill({ status: 204 }); });
  await page.goto('./?station=602');
  await expect(page.getByRole('button', { name: 'Northbound', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByRole('button', { name: 'Line 4', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.evaluate(() => { history.pushState({}, '', '?station=617'); dispatchEvent(new PopStateEvent('popstate')); });
  await expect(page.getByRole('button', { name: 'All directions', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('button', { name: 'Southbound', exact: true }).click();
  await page.goBack();
  await expect(page.getByRole('button', { name: 'Northbound', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.goForward();
  await expect(page.getByRole('button', { name: 'Southbound', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.reload();
  await expect(page.getByRole('button', { name: 'Southbound', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect.poll(() => events.filter(e => e.name === 'station_view').length, { timeout: 12000 }).toBeGreaterThan(0);
  expect(events.filter(e => e.name === 'direction').length).toBeLessThanOrEqual(1);
});

test('stats direct navigation, reload, narrow layout and offline state never start board requests or traffic', async ({ page, context }) => {
  let boards = 0, events = 0;
  page.on('request', request => { if (/\/board$/.test(request.url())) boards++; if (request.url().endsWith('/analytics/events')) events++; });
  await page.goto('./stats');
  await expect(page.getByRole('heading', { name: 'Public usage stats' })).toBeVisible();
  await expect(page.getByText('Unique browsers (estimated)', { exact: true })).toBeVisible();
  await page.setViewportSize({ width: 320, height: 740 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.getByLabel('Period').selectOption('7d');
  await expect(page.getByText(/over 7 days/)).toBeVisible();
  await page.reload();
  await expect(page.getByLabel('Period')).toHaveValue('30d');
  await page.evaluate(async () => { await navigator.serviceWorker.ready; });
  await page.reload();
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByRole('heading', { name: 'Public usage stats' })).toBeVisible();
  await expect(page.getByRole('status')).toContainText('Offline');
  expect(boards).toBe(0); expect(events).toBe(0);
  await context.setOffline(false);
  await page.getByRole('link', { name: 'Return to departures' }).click();
  await expect(page.locator('h1')).toHaveText('14 St-Union Sq');
  await page.goBack();
  await expect(page.getByRole('heading', { name: 'Public usage stats' })).toBeVisible();
});

test('failed preloads and exhausted storage leave selected board usable', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('sfn:favorites', '["602","617"]');
    Storage.prototype.setItem = () => { throw new DOMException('Full', 'QuotaExceededError'); };
  });
  await page.route('**/stations/617/board', route => route.abort());
  await page.goto('./?station=602');
  await expect(page.locator('.train-row').first()).toBeVisible();
  await page.getByRole('button', { name: 'Northbound', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Northbound', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.getByText('Feed connection interrupted. Retrying…', { exact: true })).toHaveCount(0);
});

test('refresh cadence, hidden tabs, favorite changes, and polling never inflate station views', async ({ page }) => {
  await page.clock.install({ time: new Date('2026-09-06T00:59:40Z') });
  await page.addInitScript(() => localStorage.setItem('sfn:favorites', '["602","617"]'));
  const counts: Record<string, number> = {}, events: any[] = [];
  await page.route('**/api/v1/stations/*/board', async route => { const id = route.request().url().split('/').at(-2)!; counts[id] = (counts[id] || 0) + 1; await route.continue(); });
  await page.route('**/api/v1/analytics/events', async route => { events.push(...route.request().postDataJSON().events); await route.fulfill({ status: 204 }); });
  await page.goto('./?station=602');
  await expect(page.locator('.train-row').first()).toBeVisible();
  await expect.poll(() => counts['617']).toBe(1);
  await page.clock.runFor(11000);
  await expect.poll(() => counts['602']).toBe(2); expect(counts['617']).toBe(1);
  await page.clock.runFor(21000);
  await expect.poll(() => counts['617']).toBe(2);
  expect(events.filter(e => e.name === 'station_view')).toHaveLength(1);
  expect(events.filter(e => e.name === 'session_start')).toHaveLength(1);
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: true }); document.dispatchEvent(new Event('visibilitychange')); });
  const before = { ...counts };
  await page.clock.runFor(31000); expect(counts).toEqual(before);
  await page.evaluate(() => { Object.defineProperty(document, 'hidden', { configurable: true, value: false }); document.dispatchEvent(new Event('visibilitychange')); });
  await expect.poll(() => counts['617']).toBe(before['617'] + 1);
  await page.evaluate(() => { history.pushState({}, '', '?station=617'); dispatchEvent(new PopStateEvent('popstate')); });
  await page.getByRole('button', { name: 'Remove favorite station', exact: true }).click();
  await page.evaluate(() => { history.pushState({}, '', '?station=602'); dispatchEvent(new PopStateEvent('popstate')); });
  const removedCount = counts['617'];
  await page.clock.runFor(31000); expect(counts['617']).toBe(removedCount);
  await page.getByRole('button', { name: 'Refresh departures' }).click();
  await page.clock.runFor(6000);
  expect(events.filter(e => e.name === 'station_view')).toHaveLength(3);
  await page.clock.fastForward(30 * 60000);
  await page.getByRole('button', { name: 'Northbound', exact: true }).click();
  await page.clock.runFor(6000);
  expect(events.filter(e => e.name === 'session_start')).toHaveLength(2);
});

test('selecting an in-flight favorite reuses its request and newly added favorites queue immediately', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('sfn:favorites', '["602","617"]'));
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  let count = 0;
  await page.route('**/stations/617/board', async route => { count++; await gate; await route.continue(); });
  await page.goto('./?station=602');
  await expect.poll(() => count).toBe(1);
  await page.evaluate(() => { history.pushState({}, '', '?station=617'); dispatchEvent(new PopStateEvent('popstate')); });
  release();
  await expect(page.locator('.train-row').first()).toBeVisible(); expect(count).toBe(1);
  await page.getByRole('button', { name: 'Remove favorite station', exact: true }).click();
  await page.getByRole('button', { name: 'Favorite this station', exact: true }).click();
  await expect.poll(() => count).toBe(2);
});

test('nearest favorite restores that station preferences and reset affects only it', async ({ page, context }) => {
  await context.grantPermissions(['geolocation']);
  const stations = await (await page.request.get('api/v1/stations')).json();
  const closest = stations.find((s: any) => s.id === '617');
  await context.setGeolocation({ latitude: closest.lat, longitude: closest.lon });
  await page.addInitScript(() => {
    localStorage.setItem('sfn:station', '602'); localStorage.setItem('sfn:favorites', '["602","617"]');
    localStorage.setItem('sfn:preferences', JSON.stringify({ version: 1, stations: { '602': { direction: 'NORTH', routes: ['4'] }, '617': { direction: 'SOUTH', routes: ['NONEXISTENT'], view: 'corridor' } } }));
  });
  await page.goto('./');
  await expect(page.locator('h1')).toHaveText(closest.name);
  await expect(page.getByRole('button', { name: 'Southbound', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await page.getByRole('button', { name: 'Reset filters', exact: true }).click();
  const preferences = await page.evaluate(() => JSON.parse(localStorage.getItem('sfn:preferences')!).stations);
  expect(preferences['617']).toEqual({ direction: 'ALL', routes: [], view: 'corridor' });
  expect(preferences['602']).toEqual({ direction: 'NORTH', routes: ['4'], view: 'track' });
});

test('analytics retries immutable batches in memory when storage and delivery fail', async ({ page }) => {
  await page.clock.install({ time: new Date('2026-09-06T00:59:40Z') });
  await page.addInitScript(() => { Storage.prototype.setItem = () => { throw new Error('Storage unavailable'); }; });
  const batches: any[][] = [];
  await page.route('**/api/v1/analytics/events', async route => { batches.push(route.request().postDataJSON().events); await route.fulfill({ status: batches.length === 1 ? 503 : 204 }); });
  await page.goto('./?station=602');
  await expect(page.locator('.train-row').first()).toBeVisible();
  await page.getByRole('button', { name: 'Northbound', exact: true }).click();
  await page.clock.runFor(6000);
  await expect.poll(() => batches.length).toBe(1);
  await page.clock.runFor(6000);
  await expect.poll(() => batches.length).toBe(2);
  expect(batches[1]).toEqual(batches[0]);
  expect(batches[1].map(e => e.name)).toEqual(['session_start', 'station_view', 'direction']);
  expect(new Set(batches[1].map(e => e.browser)).size).toBe(1);
  await page.clock.runFor(6000); expect(batches.length).toBe(2);
});
