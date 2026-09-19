import { test, expect } from '@playwright/test';

test.beforeEach(async ({ page }) => {
  await page.clock.install({ time: new Date('2026-09-06T00:59:40Z') });
  await page.route('**/api/v1/stations/602/board', async route => {
    const response = await route.fetch(), board = await response.json(), seed = board.departures[0];
    board.departures = Array.from({ length: 8 }, (_, i) => ({ ...seed, key: `train-${i}`, route: i < 4 ? '4' : 'L', partId: i < 4 ? '635' : 'L03', direction: 'NORTH', actualTrack: String(i % 2 + 1), scheduledTrack: undefined, time: 1788656500 + i * 60, area: i < 4 ? `Lexington Av · Uptown · Track ${i % 2 + 1}` : `Canarsie · West Side · Track ${i % 2 + 1}` }));
    await route.fulfill({ response, json: board });
  });
});

test('all views group trains, retain boarding context, expand and open details', async ({ page }) => {
  await page.goto('./?station=602');
  await expect(page.locator('.platform-card')).toHaveCount(4);
  const choose = async (label: string) => { await page.getByRole('button', { name: /^View:/ }).click(); await page.getByRole('menuitemradio', { name: label, exact: true }).click(); };
  await choose('By direction · all platforms');
  await expect(page.locator('.platform-card')).toHaveCount(1);
  await expect(page.locator('.train-row')).toHaveCount(5);
  await expect(page.locator('.count-badge')).toHaveText('8');
  await expect(page.locator('.train-boarding').last()).toContainText('West Side');
  await page.getByRole('button', { name: 'Show 3 more trains' }).click();
  await expect(page.locator('.train-row')).toHaveCount(8);
  await page.getByRole('button', { name: 'Refresh departures' }).click();
  await expect(page.locator('.train-row')).toHaveCount(8);
  for (const label of ['By direction · route families', 'By direction · station corridors', 'By service']) {
    await choose(label); await expect(page.locator('.platform-card')).toHaveCount(2);
    await expect(page.locator('.train-row')).toHaveCount(8);
  }
  await expect(page.locator('.service-section')).toHaveCount(2);
  await page.locator('.train-row').first().click();
  await expect(page.getByText('Operations ID', { exact: true })).toBeVisible();
});

test('menu keyboard, filtering, station persistence and narrow layouts', async ({ page }) => {
  await page.goto('./?station=602');
  const trigger = page.getByRole('button', { name: /^View:/ });
  await trigger.focus(); await page.keyboard.press('ArrowDown');
  await expect(page.getByRole('menuitemradio', { name: 'By track', exact: true })).toBeFocused();
  await page.keyboard.press('ArrowDown'); await page.keyboard.press('Enter');
  await expect(trigger).toBeFocused(); await expect(trigger).toHaveText('View: Direction');
  await page.reload(); await expect(trigger).toHaveText('View: Direction');
  await page.getByRole('button', { name: 'Line 4', exact: true }).click();
  await expect(page.locator('.count-badge')).toHaveText('4');
  await page.getByRole('button', { name: 'Southbound', exact: true }).click();
  await page.getByRole('button', { name: 'Reset filters', exact: true }).click();
  await expect(trigger).toHaveText('View: Direction');
  await page.evaluate(() => { history.pushState({}, '', '?station=617'); dispatchEvent(new PopStateEvent('popstate')); });
  await expect(trigger).toHaveText('View: Track');
  await page.goBack(); await expect(trigger).toHaveText('View: Direction');
  for (const width of [320, 390, 1440]) {
    await page.setViewportSize({ width, height: 1000 }); await trigger.click();
    const menu = page.getByRole('menu'); await expect(menu).toBeVisible();
    const box = (await menu.boundingBox())!; expect(box.x).toBeGreaterThanOrEqual(0); expect(box.x + box.width).toBeLessThanOrEqual(width);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.keyboard.press('Escape'); await expect(trigger).toBeFocused();
  }
  await trigger.click(); await page.locator('h1').click(); await expect(page.getByRole('menu')).toHaveCount(0);
});

test('old or invalid preferences default to track and offline grouping works', async ({ page, context }) => {
  await page.addInitScript(() => { localStorage.setItem('sfn:preferences', JSON.stringify({ version: 1, stations: { '602': { direction: 'ALL', routes: [], view: 'invalid' } } })); });
  await page.goto('./?station=602');
  await expect(page.getByRole('button', { name: 'View: Track', exact: true })).toBeVisible();
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload(); await expect(page.locator('.train-row').first()).toBeVisible();
  await context.setOffline(true); await page.reload();
  await expect(page.getByText('CACHED BOARD', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'View: Track', exact: true }).click();
  await page.getByRole('menuitemradio', { name: 'By direction · all platforms', exact: true }).click();
  await expect(page.locator('.train-time').first()).toContainText('last estimate');
  await context.setOffline(false);
});
