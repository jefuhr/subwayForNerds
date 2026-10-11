import { test as base, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { defaults, decodeNerds, type Settings } from '../../shared/settings';

const test = base.extend({ serviceWorkers: 'block' });
const now = Date.parse('2026-09-06T00:59:40Z') / 1000;
test.beforeEach(async ({ page }) => { await page.clock.install({ time: new Date(now * 1000) }); });
test.afterEach(async ({ page }) => { await page.unrouteAll({ behavior: 'wait' }); });
async function seed(page: Page, settings: Settings) {
	await page.addInitScript(settings => {
		if (!sessionStorage.getItem('seeded')) { localStorage.setItem('sfn:settings:v1', JSON.stringify({ settings, lastStation: '602' })); sessionStorage.setItem('seeded', '1'); }
	}, settings);
}
async function exportSettings(page: Page) {
	const download = page.waitForEvent('download');
	await page.getByRole('button', { name: 'Export settings', exact: true }).click();
	return decodeNerds(readFileSync((await (await download).path())!, 'utf8'));
}

test('car and complete-consist favorites highlight live feed, support any-member matching, and can be removed while absent', async ({ page }, info) => {
	const consist = { cars: [{ number: '4149', type: 'R211A' }, { number: '4148', type: 'R211A' }], updatedAt: now, fetchedAt: now, source: 'helium' };
	const board = await (await page.request.get('./api/v1/stations/602/board')).json();
	board.departures.forEach((row: any) => { row.consist = consist; });
	await page.route('**/api/v1/stations/602/board', route => route.fulfill({ json: board }));
	await page.route('**/api/v1/trips?*', async route => { const response = await route.fetch(); const data = await response.json(); data.train.consist = consist; await route.fulfill({ response, json: data }); });
	await page.goto('./?station=602');
	await page.locator('.train-row').first().click();
	await page.getByRole('button', { name: 'Favorite car R211A 4149', exact: true }).click();
	await page.getByRole('button', { name: 'Favorite consist, 2 cars', exact: true }).click();
	await page.keyboard.press('Escape');
	await expect(page.locator('.train-row').first()).toHaveClass(/favorite-train/);
	await expect(page.locator('.train-row').first()).toHaveAccessibleName(/Favorite consist/);
	await page.screenshot({ path: `artifacts/favorite-feed-${info.project.name}.png`, fullPage: false });
	// Retain only a consist member that was not individually saved.
	board.departures.forEach((row: any) => { row.consist = { ...consist, cars: [consist.cars[1]] }; });
	await page.getByRole('button', { name: 'Refresh departures' }).click();
	await expect(page.locator('.train-row').first()).not.toHaveClass(/favorite-train/);
	await page.getByRole('button', { name: 'Open settings' }).click();
	await page.getByLabel('Match saved consists').selectOption('anyCar');
	const saved = await exportSettings(page);
	expect(saved.version).toBe(2); expect(saved.settings.trainFavorites.match).toBe('anyCar');
	expect(saved.settings.trainFavorites.consists).toEqual([['nyct:R211A:4148', 'nyct:R211A:4149']]);
	await page.getByRole('button', { name: 'Close panel' }).click();
	await expect(page.locator('.train-row').first()).toHaveClass(/favorite-train/);
	await page.clock.setSystemTime(new Date((now + 301) * 1000)); await page.clock.runFor(1000);
	await expect(page.locator('.favorite-train')).toHaveCount(0);
	await page.getByRole('button', { name: 'Open settings' }).click();
	await page.getByRole('button', { name: 'Remove favorite consist, 2 cars', exact: true }).click();
	await page.getByRole('button', { name: 'Undo removal', exact: true }).click();
	expect((await exportSettings(page)).settings.trainFavorites.consists).toHaveLength(1);
	await page.getByRole('button', { name: 'Remove favorite consist, 2 cars', exact: true }).click();
	await page.getByRole('button', { name: 'Remove favorite car R211A 4149', exact: true }).click();
	expect((await exportSettings(page)).settings.trainFavorites).toEqual({ cars: [], consists: [], match: 'anyCar' });
});

test('station radius and widget override round trip through the real import preview', async ({ page }, info) => {
	await page.goto('./?station=602'); await page.getByRole('button', { name: 'Open settings' }).click();
	await page.getByLabel('App station selection', { exact: true }).selectOption('nearbyFavorite');
	await page.getByLabel('App radius in feet', { exact: true }).fill('1');
	await page.getByLabel('Follow app station selection').uncheck();
	await page.getByLabel('Widget station selection', { exact: true }).selectOption('nearbyFavorite');
	await page.getByLabel('Widget radius in feet', { exact: true }).fill('26400');
	const saved = await exportSettings(page);
	expect(saved.settings.stationSelection).toEqual({ mode: 'nearbyFavorite', radiusFeet: 1 });
	expect(saved.settings.widgets.stationSelection).toEqual({ followApp: false, selection: { mode: 'nearbyFavorite', radiusFeet: 26400 } });
	await page.screenshot({ path: `artifacts/favorite-settings-${info.project.name}.png`, fullPage: false });
	await page.getByLabel('App radius in feet', { exact: true }).fill('500');
	await page.getByLabel('App radius in feet', { exact: true }).blur();
	await page.getByLabel('Import settings file').setInputFiles({ name: 'favorites.nerds', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(saved)) });
	await expect(page.getByRole('region', { name: 'Import preview' })).toContainText('Radius (ft)');
	await page.getByRole('button', { name: 'Replace settings', exact: true }).click();
	await expect(page.getByLabel('App radius in feet', { exact: true })).toHaveValue('1');
	await page.reload(); await page.getByRole('button', { name: 'Open settings' }).click();
	await expect(page.getByLabel('Widget radius in feet', { exact: true })).toHaveValue('26400');
});

for (const [mode, radiusFeet, favorites, expected] of [
	['favorite', 5280, ['favorite'], 'Favorite'], ['closest', 5280, [], 'Closest'],
	['nearbyFavorite', 1, ['favorite'], 'Closest'], ['nearbyFavorite', 5280, ['favorite'], 'Favorite'],
] as const) test(`startup chooses ${mode} within ${radiusFeet} feet`, async ({ page }) => {
	const settings = defaults(); settings.favorites = [...favorites]; settings.stationSelection = { mode, radiusFeet };
	await seed(page, settings);
	const stations = [{ id: 'favorite', name: 'Favorite', lat: 0.01 }, { id: 'closest', name: 'Closest', lat: 0.001 }].map(s => ({ ...s, lon: 0, borough: 'M', routes: [], parts: [] }));
	await page.route('**/api/v1/stations', route => route.fulfill({ json: stations }));
	await page.route('**/api/v1/stations/*/board', route => route.fulfill({ json: { station: stations.find(s => route.request().url().includes('/' + s.id + '/')) ?? { ...stations[0], id: '602', name: 'Saved station' }, departures: [], sources: [], alerts: [], generatedAt: now } }));
	await page.addInitScript(() => { navigator.geolocation.getCurrentPosition = ok => ok({ coords: { latitude: 0, longitude: 0 }, timestamp: Date.now() } as GeolocationPosition); });
	await page.goto('./'); await expect(page.locator('h1')).toHaveText(expected);
});

test('manual navigation wins over a pending startup location fix', async ({ page }) => {
	const settings = defaults(); settings.stationSelection.mode = 'closest'; await seed(page, settings);
	await page.addInitScript(() => { navigator.geolocation.getCurrentPosition = ok => { (window as any).deliverLocation = () => ok({ coords: { latitude: 40.75529, longitude: -73.987495 }, timestamp: Date.now() } as GeolocationPosition); }; });
	await page.goto('./'); await expect.poll(() => page.evaluate(() => typeof (window as any).deliverLocation)).toBe('function');
	await page.locator('.station-name-button').click(); await page.getByRole('textbox', { name: 'Search stations' }).fill('Atlantic Barclays');
	await page.locator('.station-result>button:first-child').first().click();
	await page.evaluate(() => (window as any).deliverLocation());
	await expect(page.locator('h1')).toHaveText('Atlantic Av-Barclays Ctr');
});

test('theme cells keep just the name and swatch with usable mobile targets', async ({ page }, info) => {
	await page.goto('./?station=602'); await page.getByRole('button', { name: 'Open settings' }).click(); await page.locator('dialog').getByRole('button', { name: 'Choose theme', exact: true }).click();
	await page.getByRole('button', { name: 'Hello Kitty', exact: true }).click();
	await expect(page.locator('.theme-option small')).toHaveCount(0);
	expect(await page.locator('.theme-option').evaluateAll(cells => cells.every(cell => cell.getBoundingClientRect().height >= 44))).toBe(true);
	expect(await page.locator('dialog').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
	await page.screenshot({ path: `artifacts/favorite-themes-${info.project.name}.png` });
});
