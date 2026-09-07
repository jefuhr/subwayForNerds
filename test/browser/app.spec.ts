import { test, expect } from '@playwright/test';

test.beforeEach(async ({ page }) => {
  // Recorded feed clock: prevents replayed fixtures from impersonating live data.
  await page.clock.install({ time: new Date('2026-09-06T00:59:40Z') });
});
test('service changes stay compact, explain their source, and become last-known', async ({ page }) => {
  const timestamp = Date.parse('2026-09-06T00:59:40Z') / 1000;
  const changes = [
    { id:'track', kind:'track', classification:'unknown', label:'track 4 · scheduled 3', description:'Reported track assignment differs from the schedule.', stopIndices:[0], affectedStops:[], alertIds:[], evidence:[{source:'gtfs',timestamp,staleAfter:90}] },
    { id:'night', kind:'pattern', classification:'scheduled', label:'overnight · extra stops', description:'Matches the published overnight pattern, different from weekday daytime service.', stopIndices:[1], affectedStops:[], alertIds:[], evidence:[{source:'schedules',timestamp,staleAfter:7200}] },
    { id:'work', kind:'advisory', classification:'planned', label:'planned · boarding change', description:'Published maintenance notice.', stopIndices:[1], affectedStops:[], alertIds:['work'], advisory:true, evidence:[{source:'subway-alerts',timestamp,staleAfter:90}] }
  ];
  await page.route('**/api/v1/stations/602/board', async route => {
    const response=await route.fetch(), board=await response.json(); board.departures.forEach((d:any)=>{d.changes=changes;});
    await route.fulfill({response,json:board});
  });
  await page.route('**/api/v1/trips?*', async route => {
    const response=await route.fetch(), detail=await response.json(); detail.train.changes=changes;
    detail.train.stops[0].changes=[changes[0]];
    await route.fulfill({response,json:detail});
  });
  await page.goto('./?station=602');
  const row=page.locator('.train-row').first();
  await expect(row.locator('.change-label')).toHaveCount(3);
  await expect(row.locator('.change-more')).toHaveCount(0);
  await expect(row.locator('.change-icons .change-label').first()).toHaveAttribute('aria-label', /track 4/);
  await expect(row).toHaveAccessibleDescription(/track 4/);
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  await row.click();
  await expect(page.getByRole('heading',{name:'Different from normal'})).toBeVisible();
  await page.locator('.change-explanation summary').first().click();
  await expect(page.getByText('Reported track assignment differs from the schedule.',{exact:true})).toBeVisible();
  await expect(page.locator('.stop-link .change-label').first()).toBeVisible();
  expect(await page.locator('dialog').evaluate(el=>el.scrollWidth<=el.clientWidth)).toBe(true);
  await page.clock.fastForward(91000);
  await expect(page.locator('.change-explanation').first()).toContainText('last known');
});
test('station board loads, has no horizontal overflow, and opens complete train details', async ({ page }) => {
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  await page.goto('./?station=602');
  await expect(page.locator('h1')).toHaveText('14 St-Union Sq');
  await expect(page.locator('.train-row').first()).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.locator('.train-row').first().click();
  await expect(page.getByText('Operations ID', { exact: true })).toBeVisible();
  await expect(page.locator('.stop-sequence li').first()).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.locator('dialog')).toHaveCount(0);
  expect(errors).toEqual([]);
});
test('departures show car ranges and details show each car, then expire old reports', async ({ page }) => {
  // Synthetic enrichment of recorded departures; no live Helium dependency.
  const consist = { source: 'helium', updatedAt: Date.parse('2026-09-06T00:59:40Z') / 1000,
    fetchedAt: Date.parse('2026-09-06T00:59:40Z') / 1000,
    cars: ['4149', '4148', '4147', '4146', '4145', '4374', '4373', '4372', '4371', '4370'].map(number => ({ number, type: 'R211A' })) };
  await page.route('**/api/v1/stations/602/board', async route => {
    const response = await route.fetch(), board = await response.json();
    board.departures.forEach((d: any) => { d.consist = consist; });
    await route.fulfill({ response, json: board });
  });
  await page.route('**/api/v1/trips?*', async route => {
    const response = await route.fetch(), detail = await response.json();
    detail.train.consist = consist;
    await route.fulfill({ response, json: detail });
  });
  await page.goto('./?station=602');
  await expect(page.locator('.train-consist').first()).toHaveText('R211A · 4149–4145, 4374–4370');
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  await page.locator('.train-row').first().click();
  await expect(page.locator('.consist-cars li')).toHaveCount(10);
  await expect(page.locator('.consist-cars li').first()).toHaveText('4149R211A');
  expect(await page.locator('dialog').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  await page.clock.fastForward(301000);
  await expect(page.locator('.consist-cars li')).toHaveCount(0);
  await expect(page.getByText('Not currently available', { exact: true })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.locator('.train-consist')).toHaveCount(0);
});
test('search, favorite, restore, direction filters, and theme persistence', async ({ page }) => {
  await page.goto('./?station=602');
  await page.locator('.station-name-button').click();
  await page.getByRole('textbox', { name: 'Search stations' }).fill('Atlantic Barclays');
  await page.locator('.station-result>button:first-child').first().click();
  await expect(page.locator('h1')).toHaveText('Atlantic Av-Barclays Ctr');
  await page.getByRole('button', { name: 'Favorite this station', exact: true }).click();
  await page.getByRole('button', { name: 'Northbound', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Northbound', exact: true })).toHaveAttribute('aria-pressed', 'true');
  const themeButton = page.locator('.theme-trigger:visible, button[aria-label="Choose theme"]:visible');
  await themeButton.click();
  await page.getByRole('button', { name: /Hello Kitty/ }).click();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'hello-kitty');
  await page.getByRole('button', { name: 'Close panel' }).click();
  await page.goto('./');
  await expect(page.locator('h1')).toHaveText('Atlantic Av-Barclays Ctr');
  await expect(page.getByRole('button', { name: 'Remove favorite station' })).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'hello-kitty');
});
test('nearby stations use explicit permission and retain manual search after denial', async ({ page, context }) => {
  await context.clearPermissions();
  await page.addInitScript(() => {
    navigator.geolocation.getCurrentPosition = (_ok, fail) => { fail?.({ code: 1, message: 'denied' } as GeolocationPositionError); };
  });
  await page.goto('./?station=602');
  await page.locator('.station-name-button').click();
  await page.getByRole('button', { name: 'Use my location' }).click();
  await expect(page.getByText('Location permission is off. You can still search for any station.')).toBeVisible();
  await page.getByRole('textbox', { name: 'Search stations' }).fill('Jay Metro');
  await expect(page.locator('.station-result')).toHaveCount(1);
});
test('future stops open arrival-relative transfers and return to the train', async ({ page }) => {
  await page.goto('./?station=602');
  await page.locator('.train-row').first().click();
  await page.locator('.stop-link:enabled').first().click();
  await expect(page.locator('.transfer-view')).toBeVisible();
  await expect(page.locator('.transfer-view')).toContainText('raw time gaps');
  await expect(page.locator('.transfer-view')).toContainText('Your train:');
  await page.getByRole('button', { name: 'Back to train' }).click();
  await expect(page.getByText('Operations ID', { exact: true })).toBeVisible();
  expect(await page.locator('dialog').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
});
test('fleet is lazy, searchable, grouped, and exposes car history without overflow', async ({ page }) => {
  const requests: string[] = [];
  page.on('request', r => { if (r.url().includes('/api/v1/fleet')) requests.push(r.url()); });
  await page.goto('./?station=602');
  await expect(page.locator('.train-row').first()).toBeVisible();
  expect(requests).toHaveLength(0);
  await page.locator('button[aria-label="Open fleet"]:visible, .sidebar button:has-text("Fleet browser"):visible').click();
  await expect(page.locator('.fleet-row').first()).toBeVisible();
  await page.getByRole('textbox', { name: 'Search fleet', exact: true }).fill('4149');
  await expect(page.locator('.fleet-row')).toHaveCount(1);
  await expect(page.locator('.fleet-row')).toContainText('5 cars');
  await page.locator('.fleet-row').click();
  await expect(page.getByText('Observed changes · last 30 days', { exact: true })).toBeVisible();
  await expect(page.locator('.fleet-next')).toContainText('Next stop:');
  expect(await page.locator('dialog').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
  await page.getByRole('button', { name: 'Back to fleet', exact: true }).click();
  await page.getByRole('combobox', { name: 'Fleet grouping' }).selectOption('cars');
  await expect(page.locator('.fleet-row')).toContainText('1 car');
  await page.getByRole('textbox', { name: 'Search fleet', exact: true }).fill('OL912');
  await expect(page.locator('.fleet-row')).toContainText('0L912');
  await expect(page.locator('.fleet-row')).toContainText('Never observed');
});
test('fleet mobile search remains above a simulated keyboard', async ({ page, isMobile }) => {
  test.skip(!isMobile, 'Mobile viewport behavior');
  await page.goto('./?station=602');
  await page.getByRole('button', { name: 'Open fleet', exact: true }).click();
  await page.getByRole('textbox', { name: 'Search fleet', exact: true }).fill('4149');
  await page.evaluate(() => {
    Object.defineProperty(window.visualViewport!, 'height', { configurable: true, value: 390 });
    Object.defineProperty(window.visualViewport!, 'offsetTop', { configurable: true, value: 20 });
    window.visualViewport!.dispatchEvent(new Event('resize'));
  });
  const input = await page.getByRole('textbox', { name: 'Search fleet', exact: true }).boundingBox();
  expect(input!.y + input!.height).toBeLessThan(410);
  expect(await page.getByRole('textbox', { name: 'Search fleet', exact: true }).evaluate(el => getComputedStyle(el).fontSize)).toBe('16px');
  expect(await page.locator('dialog').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
});
test('all themes and station context render without overflow', async ({ page }) => {
  await page.goto('./?station=602');
  await expect(page.locator('.train-row').first()).toBeVisible();
  await page.locator('.theme-trigger:visible, button[aria-label="Choose theme"]:visible').click();
  const options = page.locator('.theme-option');
  await expect(options).toHaveCount(10);
  for (let i = 0; i < 10; i++) { await options.nth(i).click(); expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true); }
  await page.getByRole('button', { name: 'Close panel' }).click();
  await page.getByRole('button', { name: 'Station info' }).click();
  await expect(page.getByText('STATION FIELD NOTES')).toBeVisible();
  await expect(page.getByText('Current equipment status is unavailable or stale')).toBeVisible();
});
test('installed shell and recent board recover offline without live countdowns', async ({ page, context }) => {
  await page.goto('./?station=602');
  await expect(page.locator('.train-row').first()).toBeVisible();
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload();
  await expect(page.locator('.train-row').first()).toBeVisible();
  await context.setOffline(true);
  await page.reload();
  await expect(page.locator('h1')).toHaveText('14 St-Union Sq');
  await expect(page.getByText('CACHED BOARD', { exact: true })).toBeVisible();
  await expect(page.locator('.train-time').first()).toContainText('last estimate');
  await context.setOffline(false);
  await expect(page.getByText('LIVE FEED', { exact: true })).toBeVisible();
});

test('direct filters combine, toggle, reset, and persist', async ({ page }) => {
  await page.route('**/api/v1/stations/602/board', async route => {
    const response = await route.fetch(), board = await response.json();
    const seed = board.departures[0];
    board.departures = ['NORTH', 'SOUTH'].flatMap(direction => ['4', '5'].map(line => ({
      ...seed, key: `${direction}-${line}`, direction, route: line, time: 1788656500,
    })));
    await route.fulfill({ response, json: board });
  });
  await page.goto('./?station=602');
  const directions = page.getByRole('group', { name: 'Direction filters' });
  const lines = page.getByRole('group', { name: 'Line filters' });
  const north = directions.getByRole('button', { name: 'Northbound', exact: true });
  const all = lines.getByRole('button', { name: 'All lines', exact: true });
  await expect(page.locator('.train-row')).toHaveCount(4);
  await north.focus();
  await page.keyboard.press('Enter');
  await expect(north).toBeFocused();
  await expect(page.locator('.train-row')).toHaveCount(2);
  await lines.getByRole('button', { name: 'Line 4', exact: true }).click();
  await expect(page.locator('.train-row')).toHaveCount(1);
  await lines.getByRole('button', { name: 'Line 5', exact: true }).click();
  await expect(page.locator('.train-row')).toHaveCount(2);
  await expect(lines.locator('[aria-pressed=true]')).toHaveCount(2);
  await page.reload();
  await expect(north).toHaveAttribute('aria-pressed', 'true');
  await expect(lines.locator('[aria-pressed=true]')).toHaveCount(2);
  await expect(page.locator('.train-row')).toHaveCount(2);
  await lines.getByRole('button', { name: 'Line 4', exact: true }).click();
  await expect(page.locator('.train-row .route-bullet')).toHaveText(['5']);
  await lines.getByRole('button', { name: 'Line 5', exact: true }).click();
  await expect(all).toHaveAttribute('aria-pressed', 'true');
  await lines.getByRole('button', { name: 'Line 4', exact: true }).click();
  await all.click();
  await expect(lines.locator('[aria-pressed=true]')).toHaveCount(1);
  await directions.getByRole('button', { name: 'Southbound', exact: true }).click();
  await expect(page.locator('.platform-subheading>span:last-child')).toHaveText(['SOUTHBOUND']);
  await lines.getByRole('button', { name: 'Line L', exact: true }).click();
  await expect(page.getByText('No trains match these filters')).toBeVisible();
  await page.getByRole('button', { name: 'Reset filters', exact: true }).click();
  await expect(directions.getByRole('button', { name: 'All directions' })).toHaveAttribute('aria-pressed', 'true');
  await expect(all).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('.train-row')).toHaveCount(4);
  await expect(page.locator('dialog')).toHaveCount(0);
});

for (const width of [1440, 390, 320]) {
  test(`filter groups remain side by side at ${width}px with many routes`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto('./?station=611');
    const directions = page.getByRole('group', { name: 'Direction filters' });
    const lines = page.getByRole('group', { name: 'Line filters' });
    await expect(lines.getByRole('button').nth(8)).toBeVisible();
    const left = (await directions.boundingBox())!, right = (await lines.boundingBox())!;
    expect(left.y).toBe(right.y);
    expect(left.width).toBeCloseTo(right.width, 0);
    expect(right.x - left.x - left.width).toBeCloseTo(12, 0);
    for (const group of [directions, lines]) {
      const bounds = (await group.boundingBox())!;
      for (const button of await group.getByRole('button').all()) {
        await expect(button).toBeVisible();
        const box = (await button.boundingBox())!;
        expect(box.height).toBeGreaterThanOrEqual(44);
        expect(box.x).toBeGreaterThanOrEqual(bounds.x);
        expect(box.x + box.width).toBeLessThanOrEqual(bounds.x + bounds.width + 1);
      }
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await expect(page.locator('dialog')).toHaveCount(0);
  });
}
