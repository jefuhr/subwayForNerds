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

test('distance and time choices convert both radius editors and survive preview, export, and reload', async ({ page }, info) => {
	const settings = defaults(); settings.stationSelection.mode = 'nearbyFavorite';
	settings.widgets.stationSelection = { followApp: false, selection: { mode: 'nearbyFavorite', radiusFeet: 26400 } };
	await seed(page, settings); await page.goto('./?station=602');
	await page.getByRole('button', { name: 'Open settings' }).click();
	for (const [unit, name, app, widget] of [
		['mi', 'miles', '1', '5'], ['ft', 'feet', '5280', '26400'], ['m', 'meters', '1609.344', '8046.72'], ['km', 'kilometers', '1.609344', '8.04672'], ['auto', 'feet', '5280', '26400'],
	]) {
		await page.getByLabel('Distance units', { exact: true }).selectOption(unit);
		await expect(page.getByLabel(`App radius in ${name}`, { exact: true })).toHaveValue(app);
		await expect(page.getByLabel(`Widget radius in ${name}`, { exact: true })).toHaveValue(widget);
		const saved = await exportSettings(page);
		expect(saved.settings.stationSelection.radiusFeet).toBe(5280);
		expect(saved.settings.widgets.stationSelection.selection.radiusFeet).toBe(26400);
	}
	await page.getByLabel('Distance units', { exact: true }).selectOption('m');
	await page.getByLabel('App radius in meters', { exact: true }).fill('0.3048');
	await page.getByLabel('App radius in meters', { exact: true }).blur();
	await page.getByLabel('Widget radius in meters', { exact: true }).fill('1609.344');
	await page.getByLabel('Widget radius in meters', { exact: true }).blur();
	await page.getByLabel('Time format', { exact: true }).selectOption('24h');
	const saved = await exportSettings(page);
	expect(saved.settings.units).toEqual({ distance: 'm', time: '24h' });
	expect(saved.settings.stationSelection.radiusFeet).toBe(1);
	expect(saved.settings.widgets.stationSelection.selection.radiusFeet).toBe(5280);
	await page.getByLabel('Distance units', { exact: true }).selectOption('mi');
	await expect(page.getByLabel('App radius in miles', { exact: true })).toHaveValue('0.00018939');
	await page.getByLabel('App radius in miles', { exact: true }).focus();
	await page.getByLabel('App radius in miles', { exact: true }).blur();
	expect((await exportSettings(page)).settings.stationSelection.radiusFeet).toBe(1);
	await page.getByLabel('Time format', { exact: true }).selectOption('12h');
	await page.getByLabel('Import settings file').setInputFiles({ name: 'units.nerds', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(saved)) });
	await expect(page.getByRole('region', { name: 'Import preview' })).toContainText('Units and time · Distance units');
	await expect(page.getByRole('region', { name: 'Import preview' })).toContainText('24-hour');
	await page.getByRole('button', { name: 'Replace settings', exact: true }).click();
	await page.reload(); await page.getByRole('button', { name: 'Open settings' }).click();
	await expect(page.getByLabel('Distance units', { exact: true })).toHaveValue('m');
	await expect(page.getByLabel('Time format', { exact: true })).toHaveValue('24h');
	await expect(page.getByLabel('App radius in meters', { exact: true })).toHaveValue('0.3048');
	await expect(page.getByLabel('Widget radius in meters', { exact: true })).toHaveValue('1609.344');
	expect(await page.locator('dialog').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
	await page.getByLabel('Distance units', { exact: true }).scrollIntoViewIfNeeded();
	await page.screenshot({ path: `artifacts/units-settings-${info.project.name}.png` });
});

test('nearby station distances use each selected unit', async ({ page }) => {
	await page.addInitScript(() => { navigator.geolocation.getCurrentPosition = ok => ok({ coords: { latitude: 0, longitude: 0 }, timestamp: Date.now() } as GeolocationPosition); });
	await page.route('**/api/v1/stations', route => route.fulfill({ json: [{ id: 'units', name: 'Unit station', borough: 'M', routes: ['A'], lat: 0.004496608, lon: 0, parts: [{ id: 'part', name: 'Unit station', line: 'Test line', lat: 0.004496608, lon: 0 }] }] }));
	await page.goto('./?station=602');
	for (const [unit, distance] of [['mi', '0.31 mi'], ['ft', '1,640 ft'], ['m', '500 m'], ['km', '0.5 km'], ['auto', '500 m']]) {
		await page.getByRole('button', { name: 'Open settings' }).click();
		await page.getByLabel('Distance units', { exact: true }).selectOption(unit);
		await page.getByRole('button', { name: 'Close panel' }).click();
		await page.locator('.station-name-button').click();
		await page.getByRole('button', { name: 'Use my location', exact: true }).click();
		await expect(page.locator('.station-result small')).toHaveText(`Manhattan · ${distance} away`);
		await page.getByRole('button', { name: 'Close panel' }).click();
	}
});

test('24-hour wall clocks cover board, details, transfers, fleet history, and cached estimates', async ({ page }) => {
	const settings = defaults(); settings.units.time = '24h'; await seed(page, settings);
	const board = await (await page.request.get('./api/v1/stations/602/board')).json();
	const row = { ...board.departures[0], timestamp: now, time: now + 120, arrival: now + 120, relationship: undefined };
	board.departures = [row];
	await page.route('**/api/v1/stations/602/board', route => route.fulfill({ json: board }));
	await page.route('**/api/v1/trips?*', async route => {
		const response = await route.fetch(), data = await response.json();
		data.train.stops = [{ id: 'unit-stop', name: 'Unit stop', stationId: '602', arrival: now + 120, departure: now + 180 }];
		await route.fulfill({ response, json: data });
	});
	await page.route('**/api/v1/trips/transfers?*', route => route.fulfill({ json: {
		arrival: now + 120, originTimestamp: now, basis: 'arrival', connections: [{ ...row, time: now + 300, gap: 180, basis: 'departure' }], sources: [{ id: 'unit-source', timestamp: now, fetchedAt: now, error: null }],
	} }));
	await page.route('**/api/v1/fleet/cars/*', async route => {
		const response = await route.fetch(), data = await response.json();
		const observation = { timestamp: now, route: 'A', location: 'Unit station', tripKey: row.tripKey, consistId: 'unit-consist', cars: ['nyct:R211A:4149'], next: { name: 'Unit stop', time: now + 120 } };
		data.cars[0].reporting = true; data.cars[0].last = observation; data.history = [observation];
		await route.fulfill({ response, json: data });
	});
	await page.goto('./?station=602');
	await expect(page.locator('.train-time small')).toHaveText('21:01');
	await expect(page.locator('.train-time strong')).toHaveText(/^[12]$/);
	await expect(page.locator('.train-time div > span')).toHaveText('min');
	await page.locator('.train-row').click();
	await expect(page.locator('.stop-time')).toHaveText('21:01dep 21:02');
	await page.getByRole('button', { name: 'Transfers at Unit stop', exact: true }).click();
	await expect(page.locator('.transfer-view')).toContainText('Your train: 21:01');
	await expect(page.locator('.transfer-row')).toContainText('21:04');
	await page.getByText('Prediction sources', { exact: true }).click();
	await expect(page.locator('.transfer-view')).toContainText('unit-source · 20:59');
	await page.getByRole('button', { name: 'Close panel' }).click();
	// Opening an individually saved car exercises the same fleet screen as a car tile.
	await page.getByRole('button', { name: 'Open settings' }).click();
	const file = await exportSettings(page); file.settings.trainFavorites.cars = ['nyct:R211A:4149'];
	await page.getByLabel('Import settings file').setInputFiles({ name: 'car.nerds', mimeType: 'application/json', buffer: Buffer.from(JSON.stringify(file)) });
	await page.getByRole('button', { name: 'Replace settings', exact: true }).click();
	await page.getByRole('button', { name: 'R211A 4149', exact: true }).click();
	await expect(page.locator('.fleet-next')).toContainText('21:01 estimated');
	await expect(page.locator('.fleet-history')).toContainText('20:59:40 ET');
	await page.getByRole('button', { name: 'Close panel' }).click();
	await page.evaluate(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, value: false }); window.dispatchEvent(new Event('offline')); });
	await expect(page.locator('.train-time strong')).toHaveText('21:01');
	await expect(page.locator('.train-time')).toContainText('last estimate');
});
