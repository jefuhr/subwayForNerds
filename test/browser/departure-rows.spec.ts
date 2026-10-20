import { test, expect, type Page } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import { defaults } from '../../shared/settings';

const now = 1788656380;
const labels = ['Track source (reported/scheduled)', 'Position on one line', 'Car numbers', 'Gap after previous train'];
const chooseView = async (page: Page, name: string) => {
	await page.getByRole('button', { name: /^View:/ }).click();
	await page.getByRole('menuitemradio', { name, exact: true }).click();
};
const toggle = async (page: Page, label: string) => {
	await page.getByRole('button', { name: 'Open settings' }).click();
	await page.getByLabel(label, { exact: true }).click();
	await page.getByRole('button', { name: 'Close panel' }).click();
};

const mockRows = async (page: Page, customize = (rows: any[]) => rows) => {
	await page.unroute('**/api/v1/stations/602/board');
	await page.route('**/api/v1/stations/602/board', async route => {
		const response = await route.fetch(), board = await response.json();
		const seed = board.departures.find((row: any) => row.consist) || board.departures[0];
		board.departures = customize(Array.from({ length: 3 }, (_, index) => ({
			...seed, key: `row-display-${index}`, route: '4', partId: '635', direction: 'NORTH',
			actualTrack: index < 2 ? 'A4' : undefined, scheduledTrack: 'A4',
			area: 'Lex · Uptown · Track A4', destination: 'Woodlawn',
			time: now + 120 + index * 300, timestamp: now, staleAfter: 90,
			location: 'At Newkirk Plaza', stopsAway: 1, locationTimestamp: now - 25,
			consist: { cars: [{ number: '4149', type: 'R211A' }], updatedAt: now, fetchedAt: now, source: 'helium' },
			changes: [], alerts: [], relationship: 'SCHEDULED', assigned: true,
		})));
		await route.fulfill({ response, json: board });
	});
};
test.use({ serviceWorkers: 'block' });
test.beforeEach(async ({ page }) => {
	await page.clock.setFixedTime(new Date(now * 1000));
	await mockRows(page);
});

test('default rows are compact and each direct setting changes rows and persists', async ({ page }, testInfo) => {
	const settings = defaults(); settings.trainFavorites.cars = ['nyct:R211A:4149'];
	await page.addInitScript(settings => { if (!localStorage.getItem('sfn:settings:v1')) localStorage.setItem('sfn:settings:v1', JSON.stringify({ settings, lastStation: '602' })); }, settings);
	await page.goto('./?station=602');
	await expect(page.locator('.train-row')).toHaveCount(3);
	await expect(page.locator('.platform-track')).toHaveText('TRACK A4');
	await chooseView(page, 'By direction · all platforms');
	await expect(page.locator('.train-boarding').first()).toHaveText('Lex · Uptown · Track A4');
	await expect(page.locator('.train-boarding').last()).not.toContainText('scheduled');
	const position = page.locator('.train-location').first();
	await expect(position).toHaveText('At Newkirk Plaza · 1 stop away · 25s ago');
	await expect(position.locator(':scope > small')).toHaveCount(0);
	await expect(page.locator('.train-consist')).toHaveCount(3);
	await expect(page.locator('.train-time').nth(1)).toContainText('+5m after previous');
	await mkdir('artifacts', { recursive: true });
	await page.screenshot({ path: `artifacts/departure-rows-default-${testInfo.project.name}.png`, fullPage: true });

	await toggle(page, labels[0]);
	await expect(page.locator('.train-boarding').first()).toContainText('reported track');
	await expect(page.locator('.train-boarding').last()).toContainText('scheduled track');
	await chooseView(page, 'By track');
	await expect(page.locator('.platform-track')).toContainText('reported');
	await chooseView(page, 'By direction · all platforms');
	await toggle(page, labels[1]);
	await expect(position.locator(':scope > span')).toHaveText('At Newkirk Plaza');
	await expect(position.locator(':scope > small')).toHaveText('1 stop away · 25s ago');
	await toggle(page, labels[2]);
	await expect(page.locator('.train-consist')).toHaveCount(0);
	await expect(page.locator('.train-row.favorite-train')).toHaveCount(3);
	await expect(page.locator('.favorite-train-label').first()).toContainText('Favorite cars: R211A 4149');
	await toggle(page, labels[3]);
	await expect(page.locator('.train-time').nth(1)).not.toContainText('after previous');
	await expect(page.locator('.train-time').nth(1).locator('small')).toHaveText('9:06 PM');
	await page.screenshot({ path: `artifacts/departure-rows-all-toggled-${testInfo.project.name}.png`, fullPage: true });
	await page.reload();
	await expect(page.locator('.train-consist')).toHaveCount(0);
	await expect(page.locator('.train-location').first().locator('small')).toBeVisible();
	await page.getByRole('button', { name: 'Open settings' }).click();
	await expect(page.getByRole('heading', { name: 'Departure rows', exact: true })).toBeVisible();
	for (const [index, label] of labels.entries()) await expect(page.getByLabel(label, { exact: true })).toBeChecked({ checked: index === 0 });
	await expect(page.getByText('Controls the details shown in departure rows.', { exact: true })).toBeVisible();
});

test('combined positions keep historical prefixes, slow zones and missing-part fallbacks', async ({ page }) => {
	await mockRows(page, rows => {
		rows[0].locationTimestamp = now - 120;
		rows[0].slowZone = { from: 'a', to: 'b', segment: 'Newkirk Plaza to Avenue H', kind: 'slow', since: '2026-09-01', through: '2026-09-30', extraSeconds: 42, baselineSeconds: 90, slowDays: 3 };
		rows[1].location = ''; rows[1].stopsAway = 2;
		rows[2].location = ''; delete rows[2].stopsAway; delete rows[2].locationTimestamp;
		delete rows[2].actualTrack; delete rows[2].scheduledTrack; rows[2].area = 'Lex · Uptown';
		return rows;
	});
	await page.goto('./?station=602');
	// Unknown-track grouping is still useful context when track provenance is hidden.
	await expect(page.locator('.platform-track').filter({ hasText: 'TRACK UNKNOWN' }).locator('span')).toHaveText('direction group');
	await chooseView(page, 'By direction · all platforms');
	const positions = page.locator('.train-location');
	await expect(positions.nth(0)).toContainText('Last report: At Newkirk Plaza · 1 stop away · 2m ago');
	await expect(positions.nth(0).locator('.slow-zone-tag')).toHaveText('+42s');
	await expect(positions.nth(1)).toHaveText('2 stops away · 25s ago');
	await expect(positions.nth(2)).toHaveText('Stop-relative position');
	await expect(page.locator('.train-boarding').last()).toContainText('track unknown');
	for (const width of [320, 390, 1800]) {
		await page.setViewportSize({ width, height: 1000 });
		await expect(positions.nth(0)).toBeVisible();
		expect(await positions.nth(0).evaluate(element => element.scrollWidth <= element.clientWidth)).toBe(true);
		expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
	}
});

test('NJ Transit GPS rows retain their two-line position layout for either setting', async ({ page }) => {
	await mockRows(page, rows => rows.map(row => ({ ...row, route: 'NJT-HBLR', vehiclePosition: {
		id: 'gps', provider: 'njt-bus-g2', vehicleId: '123', route: 'NJT-HBLR', lat: 40.7, lon: -74,
		stopName: 'Hoboken Terminal', timestamp: now - 25, fetchedAt: now,
	} })));
	await page.goto('./?station=602');
	const position = page.locator('.train-location').first();
	await expect(position.locator(':scope > span')).toHaveText('Hoboken Terminal');
	await expect(position.locator(':scope > small')).toHaveText('1 stop away · 25s ago');
	await toggle(page, labels[1]);
	await expect(position.locator(':scope > span')).toHaveText('Hoboken Terminal');
	await expect(position.locator(':scope > small')).toHaveText('1 stop away · 25s ago');
});
