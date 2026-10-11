import { test, expect } from '@playwright/test';

test('NJT stations support search, favorites and an honest departure directory', async ({ page }) => {
  await page.goto('./?station=njt-lr-30829');
  const active = page.locator('.active-page');
  await expect(active.locator('h1')).toHaveText('Hoboken Terminal (HBLR)');
  await expect(active.getByText('STATION DIRECTORY', { exact: true })).toBeVisible();
  await expect(active.getByRole('link', { name: 'NJ Transit departures' })).toHaveAttribute('href', 'https://www.njtransit.com/dv-to');
  await expect(active.getByText('AWAITING LIVE DATA', { exact: true })).toHaveCount(0);
  await expect(active.getByRole('button', { name: 'Refresh departures' })).toHaveCount(0);
  await active.getByRole('button', { name: 'Favorite this station', exact: true }).click();
  await expect(active.getByRole('button', { name: 'Remove favorite station', exact: true })).toBeVisible();
  await active.locator('.station-name-button').click();
  await expect(page.locator('dialog[open]')).toBeVisible();
  const search = page.getByRole('textbox', { name: 'Search stations' });
  for (const [term, count] of [['NJT', 62], ['Hudson-Bergen', 24], ['light rail', 62], ['HBLR', 24], ['NLR', 17], ['River LINE', 21], ['30776', 1], ['Bayonne', 4]] as const) {
    await search.fill(term);
    await expect(page.locator('.station-result')).toHaveCount(count);
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBeTruthy();
});
