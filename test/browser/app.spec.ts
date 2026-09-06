import { test, expect } from '@playwright/test';

test.beforeEach(async ({ page }) => {
  // Recorded feed clock: prevents replayed fixtures from impersonating live data.
  await page.clock.install({ time: new Date('2026-09-06T00:59:40Z') });
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
test('search, favorite, restore, direction filters, and theme persistence', async ({ page }) => {
  await page.goto('./?station=602');
  await page.locator('.station-name-button').click();
  await page.getByRole('textbox', { name: 'Search stations' }).fill('Atlantic Barclays');
  await page.locator('.station-result>button:first-child').first().click();
  await expect(page.locator('h1')).toHaveText('Atlantic Av-Barclays Ctr');
  await page.getByRole('button', { name: 'Favorite this station', exact: true }).click();
  await page.getByRole('button', { name: 'Choose direction', exact: true }).click();
  await page.getByRole('button', { name: 'Northbound', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Choose direction', exact: true })).toContainText('Northbound');
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
test('downstream comparison ranks direct trains and line filters can be reset', async ({ page }) => {
  await page.goto('./?station=602');
  await expect(page.locator('.train-row').first()).toBeVisible();
  const destination = page.getByRole('combobox', { name: 'Compare arrivals at a downstream station' });
  await destination.selectOption({ index: 1 });
  await expect(page.locator('.comparison-note')).toBeVisible();
  await page.getByRole('button', { name: 'Lines', exact: true }).click();
  await page.locator('.route-filters button').first().click();
  await page.getByRole('button', { name: 'Back to the board' }).click();
  await expect(page.locator('.filter-button')).toContainText('(1)');
  await page.locator('.filter-button').click();
  await page.getByRole('button', { name: 'Show every line' }).click();
  await page.getByRole('button', { name: 'Back to the board' }).click();
  await expect(page.locator('.filter-button')).not.toContainText('(1)');
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
