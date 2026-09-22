import { test, expect } from '@playwright/test';

test('PATH stations are searchable and support distinct direction filters on mobile and desktop', async ({ page }) => {
  await page.goto('./?station=path-09s');
  const active = page.locator('.active-page');
  await expect(active.locator('h1')).toHaveText('9th Street (PATH)');
  await expect(active.getByRole('button', { name: 'To New York', exact: true })).toBeVisible();
  await active.getByRole('button', { name: 'To New Jersey', exact: true }).click();
  await expect(active.getByRole('button', { name: 'To New Jersey', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await active.locator('.station-name-button').click();
  await expect(page.locator('dialog[open]')).toBeVisible();
  await page.getByRole('textbox', { name: 'Search stations' }).fill('PATH New Jersey');
  await expect(page.locator('.station-result')).toHaveCount(7);
  await page.getByRole('textbox', { name: 'Search stations' }).fill('PATH');
  await expect(page.locator('.station-result')).toHaveCount(13);
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBeTruthy();
});
