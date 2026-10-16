import { test, expect, type Page } from '@playwright/test';

// The fixture service injects synthetic Transit Lab rows: a 4 train approaching 23 St
// is in a 28 St → 23 St zone, with a disruption further along its route.
test.beforeEach(async ({ page }) => {
	await page.clock.install({ time: new Date('2026-09-06T00:59:40Z') });
});
test.afterEach(async ({ page }) => {
	await page.unrouteAll({ behavior: 'wait' });
});
const fits = (page: Page, selector: string) => page.locator(selector).first().evaluate(el => el.scrollWidth <= el.clientWidth);

test('a train in an estimated slow zone is tagged on the board and its zones are placed along the route', async ({ page }, testInfo) => {
	const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
	await page.goto('./?station=602');
	const tagged = page.locator('.train-row', { has: page.locator('.slow-zone-tag') });
	await expect(tagged.first()).toBeVisible();
	await expect(tagged.first().locator('.slow-zone-tag')).toHaveText('+42s');
	await expect(tagged.first().locator('.slow-zone-tag')).toHaveAttribute('title', 'In an estimated slow zone: 28 St → 23 St-Baruch College, typically 42s slower');
	await expect(tagged.first()).toHaveAttribute('aria-label', /In an estimated slow zone: 28 St → 23 St-Baruch College, typically 42s slower\./);
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
	await tagged.first().scrollIntoViewIfNeeded();
	await page.screenshot({ path: `artifacts/slow-zones-board-${testInfo.project.name}.png` });

	await tagged.first().click();
	await expect(page.locator('.slow-zone-summary')).toHaveText('2 estimated slow zones ahead · about +2m 56s typical');
	const segments = page.locator('.stop-sequence .slow-segment');
	await expect(segments).toHaveCount(2);
	await expect(segments.nth(0)).toContainText('slow zone · now');
	await expect(segments.nth(0)).toContainText('28 St → 23 St-Baruch College · +42s on a 1m 32s run · since Aug 10');
	await expect(segments.nth(0).locator('xpath=following-sibling::li[1]')).toContainText('23 St-Baruch College');
	await expect(segments.nth(1)).toContainText('major slowdown');
	await expect(segments.nth(1)).not.toContainText('now');
	await expect(segments.nth(1)).toContainText('Wall St → Bowling Green · +2m 14s on a 1m 28s run · since Aug 31');
	await expect(segments.nth(1).locator('xpath=following-sibling::li[1]')).toContainText('Bowling Green');
	await expect(page.getByText(/estimated from weekday daytime run times by Transit Lab \(transitlab\.nyc, CC BY 4\.0\)/)).toBeVisible();
	expect(await fits(page, 'dialog')).toBe(true);
	await segments.nth(0).scrollIntoViewIfNeeded();
	await page.screenshot({ path: `artifacts/slow-zones-detail-${testInfo.project.name}.png` });
	await page.keyboard.press('Escape');

	// A train with a zone ahead but not currently inside one keeps a quiet board row.
	const lTrain = page.locator('.train-row', { hasText: '8 Av' }).first();
	await expect(lTrain).toBeVisible();
	await expect(lTrain.locator('.slow-zone-tag')).toHaveCount(0);
	expect(errors).toEqual([]);
});

test('a cached board does not claim a train is in a slow zone now', async ({ page, context, browserName }) => {
	test.skip(browserName === 'webkit', 'WebKit offline emulation is unreliable: https://github.com/microsoft/playwright/issues/42775');
	await page.goto('./?station=602');
	await expect(page.locator('.slow-zone-tag').first()).toBeVisible();
	await page.evaluate(() => navigator.serviceWorker.ready);
	await page.reload();
	await expect(page.locator('.slow-zone-tag').first()).toBeVisible();
	await context.setOffline(true);
	await page.reload();
	await expect(page.getByText('CACHED BOARD', { exact: true })).toBeVisible();
	await expect(page.locator('.train-row').first()).toBeVisible();
	await expect(page.locator('.slow-zone-tag')).toHaveCount(0);
	await context.setOffline(false);
	await expect(page.getByText('LIVE FEED', { exact: true })).toBeVisible();
	await expect(page.locator('.slow-zone-tag').first()).toBeVisible();
});
