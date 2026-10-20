import { test, expect } from '@playwright/test';
import { mkdir } from 'node:fs/promises';

test.use({ serviceWorkers: 'block' });
test.beforeEach(async ({ page }) => {
	await page.clock.setFixedTime(new Date(1788656380 * 1000));
});

test('Culver departures show each train trunk and a compact boarding area', async ({ page }, testInfo) => {
	await page.goto('./?station=241');
	await expect(page.locator('.train-row').filter({ hasText: 'Crosstown–Culver' }).first()).toBeVisible();
	await expect(page.locator('.train-row').filter({ hasText: '6 Av–Culver' }).first()).toBeVisible();
	await page.getByRole('button', { name: /^View:/ }).click();
	await page.getByRole('menuitemradio', { name: 'By direction · all platforms', exact: true }).click();
	await expect(page.locator('.train-boarding').first()).toHaveText('Northbound · Track B2');
	await expect(page.locator('.train-row').first()).not.toContainText('6th Av - Culver');
	await mkdir('artifacts/trunk', { recursive: true });
	await page.screenshot({ path: `artifacts/trunk/culver-${testInfo.project.name}.png`, fullPage: true });
});

test('a multi-segment Atlantic complex retains its short physical boarding segment', async ({ page }, testInfo) => {
	await page.goto('./?station=617');
	await page.getByRole('button', { name: /^View:/ }).click();
	await page.getByRole('menuitemradio', { name: 'By direction · all platforms', exact: true }).click();
	const brighton = page.locator('.train-row').filter({ hasText: 'Broadway–Brighton' }).first();
	await expect(brighton).toBeVisible();
	await expect(brighton.locator('.train-boarding')).toContainText('Brighton ·');
	await expect(brighton).not.toContainText('Broadway - Brighton');
	await mkdir('artifacts/trunk', { recursive: true });
	await page.screenshot({ path: `artifacts/trunk/atlantic-${testInfo.project.name}.png`, fullPage: true });
});
