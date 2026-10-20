import { test as base, expect, type Page } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { decodeNerds, defaults, type Settings } from '../../shared/settings';

// Synthetic trip and transfer responses; the opened station board is the real fixture board.
const test = base.extend({ serviceWorkers: 'block' });
const now = Date.parse('2026-09-06T00:59:40Z') / 1000;
test.beforeEach(async ({ page }) => { await page.clock.install({ time: new Date(now * 1000) }); });
test.afterEach(async ({ page }) => { await page.unrouteAll({ behavior: 'wait' }); });

async function seed(page: Page, settings: Settings | Record<string, unknown>) {
	await page.addInitScript(settings => {
		if (!sessionStorage.getItem('seeded')) { localStorage.setItem('sfn:settings:v1', JSON.stringify({ settings, lastStation: '602' })); sessionStorage.setItem('seeded', '1'); }
	}, settings);
}
const stored = (page: Page) => page.evaluate(() => JSON.parse(localStorage.getItem('sfn:settings:v1')!).settings as Settings);
// `busy` models a long ride and a busy complex: many stops before the transfer and many connections.
// `slow` holds one response back so the other settles first.
async function routeTransfers(page: Page, { busy = false, slow }: { busy?: boolean; slow?: 'train' | 'transfers' } = {}) {
	const hold = (part: 'train' | 'transfers') => slow === part ? new Promise(resolve => setTimeout(resolve, 600)) : undefined;
	const stations = await (await page.request.get('./api/v1/stations')).json();
	const board = await (await page.request.get('./api/v1/stations/602/board')).json();
	const template = { ...board.departures[0], consist: undefined, staleAfter: undefined, changes: [], relationship: undefined, timestamp: now, basis: 'departure' };
	const connection = (key: string, route: string, direction: string, destination: string, minutes: number) =>
		({ ...template, key, tripKey: key, route, direction, destination, area: destination + ' platform', time: now + minutes * 60, gap: (minutes - 5) * 60 });
	await page.route('**/api/v1/trips?*', async route => {
		const response = await route.fetch(), data = await response.json();
		await hold('train');
		data.train.stops = [
			...(busy ? Array.from({ length: 24 }, (_, i) => ({ id: 'early' + i, name: 'Earlier stop ' + i, stationId: '617', sequence: i - 20, arrival: now + 20 + i * 10, departure: now + 25 + i * 10 })) : []),
			{ id: 'R16N', name: 'Times Sq-42 St', stationId: '611', sequence: 5, arrival: now + 300, departure: now + 330 },
			...Array.from({ length: 12 }, (_, i) => ({ id: 'far' + i, name: 'Later stop ' + i, stationId: '617', sequence: 6 + i, arrival: now + 600 + i * 60, departure: now + 630 + i * 60 })),
		];
		await route.fulfill({ response, json: data });
	});
	await page.route('**/api/v1/trips/transfers?*', async route => { await hold('transfers'); await route.fulfill({ json: {
		station: stations.find((s: { id: string }) => s.id === '611'), arrival: now + 300, basis: 'arrival', originTimestamp: now,
		connections: [connection('c7', '7', 'SOUTH', 'Flushing test', 7), connection('cs', 'GS', 'NORTH', 'Shuttle test', 8), connection('c1', '1', 'NORTH', 'Uptown test', 9),
			...(busy ? ['2', '3', 'A', 'C', 'E', 'N', 'Q', 'R', 'W'].flatMap((route, i) => ['NORTH', 'SOUTH'].map((direction, j) => connection(`b${route}${direction}`, route, direction, `${route} ${direction.toLowerCase()} test`, 10 + i * 2 + j))) : [])],
		sources: [{ id: 'transfer-source', timestamp: now, fetchedAt: now, error: null }],
	} }); });
}
async function openTransfers(page: Page) {
	await page.goto('./?station=602');
	await page.locator('.active-page .train-row').first().click();
	const stop = page.getByRole('button', { name: 'Transfers at Times Sq-42 St', exact: true });
	await stop.scrollIntoViewIfNeeded();
	const trainScroll = await page.locator('dialog').evaluate(el => el.scrollTop);
	await stop.click();
	await expect(page.locator('.transfer-view h3')).toHaveText('Transfers at Times Sq-42 St');
	return trainScroll;
}
const transferLines = (page: Page) => page.getByRole('group', { name: 'Transfer line filters' });
const transferDirections = (page: Page) => page.getByRole('group', { name: 'Transfer direction filters' });
const dialogScroll = (page: Page) => page.locator('dialog').evaluate(el => el.scrollTop);

test('shared transfer filters edit the target station board and Back returns to the transfer, then the train', async ({ page }) => {
	const settings = defaults();
	settings.favorites = ['602'];
	settings.stations['602'] = { direction: 'SOUTH', routes: ['L'], view: 'track' };
	settings.stations['611'] = { direction: 'ALL', routes: [], view: 'family' };
	settings.hiddenRoutes = ['1'];
	await seed(page, settings); await routeTransfers(page);
	const trainScroll = await openTransfers(page);
	// Choices come from the transfer station (not the 602 main board), aliases fold GS into S, hidden lines vanish.
	await expect(transferLines(page).getByRole('button', { name: 'Line S', exact: true })).toBeVisible();
	await expect(transferLines(page).getByRole('button', { name: 'Line 7', exact: true })).toBeVisible();
	await expect(transferLines(page).getByRole('button', { name: 'Line 1', exact: true })).toHaveCount(0);
	await expect(transferLines(page).getByRole('button', { name: 'Line L', exact: true })).toHaveCount(0);
	await expect(transferLines(page).getByRole('button', { name: 'All lines' })).toHaveAttribute('aria-pressed', 'true');
	await expect(page.locator('.transfer-row')).toHaveCount(2);
	await transferLines(page).getByRole('button', { name: 'Line S', exact: true }).click();
	await expect(page.locator('.transfer-row')).toHaveCount(1);
	await expect(page.locator('.transfer-row')).toContainText('Shuttle test');
	await transferDirections(page).getByRole('button', { name: 'Southbound' }).click();
	await expect(page.locator('.transfer-row')).toHaveCount(0);
	await expect(page.getByRole('heading', { name: 'No connections match these filters' })).toBeVisible();
	await page.getByRole('button', { name: 'Reset filters' }).click();
	await expect(page.locator('.transfer-row')).toHaveCount(2);
	await transferLines(page).getByRole('button', { name: 'Line S', exact: true }).click();
	let saved = await stored(page);
	expect(saved.stations['611']).toEqual({ direction: 'ALL', routes: ['S'], view: 'family' });
	expect(saved.stations['602']).toEqual({ direction: 'SOUTH', routes: ['L'], view: 'track' });
	expect(saved.transfers).toEqual({ separateFilters: false, stations: {} });
	expect(saved.hiddenRoutes).toEqual(['1']);

	const transferScroll = await page.locator('dialog').evaluate(el => { el.scrollTop = 120; return el.scrollTop; });
	await page.getByRole('button', { name: 'Open station board' }).click();
	await expect(page.locator('dialog')).toHaveCount(0);
	await expect(page).toHaveURL(/station=611/);
	await expect(page.locator('.active-page .station-name-button h1')).toContainText('Times Sq-42 St');
	await expect(page.locator('.active-page .train-row').first()).toBeVisible();
	// Shared mode: the board shows the line chosen in the transfer view.
	await expect(page.getByRole('group', { name: 'Line filters' }).getByRole('button', { name: 'Line S', exact: true })).toHaveAttribute('aria-pressed', 'true');
	await expect(page.getByRole('button', { name: 'Back to transfers at Times Sq-42 St' })).toBeVisible();

	await page.goBack();
	await expect(page.locator('.transfer-view h3')).toHaveText('Transfers at Times Sq-42 St');
	await expect(page.locator('.transfer-row')).toHaveCount(1);
	await expect.poll(() => dialogScroll(page)).toBe(transferScroll);
	await expect(page).toHaveURL(/station=611/);
	await page.goBack();
	await expect(page.getByText('Operations ID', { exact: true })).toBeVisible();
	await expect(page.locator('.transfer-view')).toHaveCount(0);
	await expect.poll(() => dialogScroll(page)).toBe(trainScroll);
	// The board stays on the newly opened station underneath the restored train.
	await expect(page.locator('.active-page .station-name-button h1')).toContainText('Times Sq-42 St');

	// The explicit affordances walk the same history entries.
	await page.getByRole('button', { name: 'Transfers at Times Sq-42 St', exact: true }).click();
	await page.getByRole('button', { name: 'Open station board' }).click();
	await expect(page.locator('dialog')).toHaveCount(0);
	await page.getByRole('button', { name: 'Back to transfers at Times Sq-42 St' }).click();
	await expect(page.locator('.transfer-view h3')).toHaveText('Transfers at Times Sq-42 St');
	await page.getByRole('button', { name: 'Back to train' }).click();
	await expect(page.getByText('Operations ID', { exact: true })).toBeVisible();
	await page.getByRole('button', { name: 'Close panel' }).click();
	await expect(page.locator('dialog')).toHaveCount(0);
	await expect(page.locator('.active-page .station-name-button h1')).toContainText('Times Sq-42 St');
	saved = await stored(page);
	expect(saved.stations['611'].routes).toEqual(['S']);
});

test('separate transfer filters copy the board once, edit independently and survive the settings toggle', async ({ page }) => {
	const settings = defaults();
	settings.stations['611'] = { direction: 'NORTH', routes: [], view: 'track' };
	settings.transfers.separateFilters = true;
	await seed(page, settings); await routeTransfers(page);
	await openTransfers(page);
	await expect(transferDirections(page).getByRole('button', { name: 'Northbound' })).toHaveAttribute('aria-pressed', 'true');
	await expect(page.locator('.transfer-row')).toHaveCount(2);
	await expect.poll(async () => (await stored(page)).transfers.stations['611']).toEqual({ direction: 'NORTH', routes: [] });
	await transferDirections(page).getByRole('button', { name: 'All directions' }).click();
	await transferLines(page).getByRole('button', { name: 'Line 7', exact: true }).click();
	await expect(page.locator('.transfer-row')).toHaveCount(1);
	let saved = await stored(page);
	expect(saved.transfers.stations['611']).toEqual({ direction: 'ALL', routes: ['7'] });
	expect(saved.stations['611']).toEqual({ direction: 'NORTH', routes: [], view: 'track' });
	await page.getByRole('button', { name: 'Open station board' }).click();
	await expect(page.getByRole('group', { name: 'Direction filters' }).getByRole('button', { name: 'Northbound' })).toHaveAttribute('aria-pressed', 'true');
	await expect(page.getByRole('group', { name: 'Line filters' }).getByRole('button', { name: 'All lines' })).toHaveAttribute('aria-pressed', 'true');
	await page.getByRole('button', { name: 'Open settings' }).click();
	const toggle = page.getByRole('checkbox', { name: 'Save transfer filters separately' });
	await expect(toggle).toBeChecked();
	await toggle.uncheck();
	saved = await stored(page);
	expect(saved.transfers).toEqual({ separateFilters: false, stations: { '611': { direction: 'ALL', routes: ['7'] } } });
	await toggle.check();
	await page.getByRole('button', { name: 'Close panel' }).click();
	await page.goBack();
	await expect(page.locator('.transfer-row')).toHaveCount(1);
	await expect(transferLines(page).getByRole('button', { name: 'Line 7', exact: true })).toHaveAttribute('aria-pressed', 'true');
});

for (const slow of ['train', 'transfers'] as const) test(`Back restores nonzero transfer and train scroll positions when the ${slow} response settles last`, async ({ page }) => {
	await routeTransfers(page, { busy: true, slow });
	const trainScroll = await openTransfers(page);
	expect(trainScroll).toBeGreaterThan(0);
	await expect(page.locator('.transfer-row')).toHaveCount(21);
	// Scroll past the sheet heading while the button stays fully visible, so tapping it
	// does not scroll the sheet back first; that is the position Back must restore.
	const open = page.getByRole('button', { name: 'Open station board' });
	const transferScroll = await open.evaluate(button => {
		const dialog = button.closest('dialog')!;
		dialog.scrollTop += button.getBoundingClientRect().top - dialog.getBoundingClientRect().top - 8;
		return dialog.scrollTop;
	});
	expect(transferScroll).toBeGreaterThan(0);
	const buttonOffset = () => open.evaluate(button => button.getBoundingClientRect().top - button.closest('dialog')!.getBoundingClientRect().top);
	const openedAt = await buttonOffset();
	await expect(open).toBeInViewport({ ratio: 1 });
	await open.click();
	await expect(page.locator('dialog')).toHaveCount(0);
	await expect(page.locator('.active-page .station-name-button h1')).toContainText('Times Sq-42 St');
	await page.goBack();
	await expect(page.locator('.transfer-row')).toHaveCount(21);
	await expect(page.getByText('Operations ID', { exact: true })).toBeAttached();
	await expect.poll(() => dialogScroll(page)).toBe(transferScroll);
	// Same visual position as when the board opened, not just the same number.
	expect(Math.abs(await buttonOffset() - openedAt)).toBeLessThanOrEqual(1);
	await page.goBack();
	await expect(page.getByText('Operations ID', { exact: true })).toBeVisible();
	await expect(page.locator('.transfer-view')).toHaveCount(0);
	await expect.poll(() => dialogScroll(page)).toBe(trainScroll);
	await expect(page.getByRole('button', { name: 'Transfers at Times Sq-42 St', exact: true })).toBeInViewport();
});
test('restoration stays distinct under a frozen clock across repeated same-station opens', async ({ page }) => {
	await page.clock.setFixedTime(new Date(now * 1000));
	await routeTransfers(page);
	await openTransfers(page);
	for (let round = 0; round < 2; round++) {
		await page.getByRole('button', { name: 'Open station board' }).click();
		await expect(page.locator('dialog')).toHaveCount(0);
		await expect(page.locator('.active-page .station-name-button h1')).toContainText('Times Sq-42 St');
		await page.goBack();
		await expect(page.locator('.transfer-view h3')).toHaveText('Transfers at Times Sq-42 St');
	}
	// Two opens from restored transfers: Back walks transfer -> train -> transfer -> train.
	await page.goBack();
	await expect(page.getByText('Operations ID', { exact: true })).toBeVisible();
	await expect(page.locator('.transfer-view')).toHaveCount(0);
	await page.goBack();
	await expect(page.locator('.transfer-view h3')).toHaveText('Transfers at Times Sq-42 St');
	await page.goBack();
	await expect(page.getByText('Operations ID', { exact: true })).toBeVisible();
	await expect(page.locator('.transfer-view')).toHaveCount(0);
	await page.goBack();
	await expect(page.locator('dialog')).toHaveCount(0);
	await expect(page).toHaveURL(/station=602/);
});
test('open station board stays available when transfer predictions are unavailable', async ({ page }) => {
	await routeTransfers(page);
	await page.route('**/api/v1/trips/transfers?*', route => route.fulfill({ status: 503, json: { error: 'down' } }));
	await openTransfers(page);
	await expect(page.locator('.transfer-view')).toContainText('Transfer predictions unavailable');
	await page.getByRole('button', { name: 'Open station board' }).click();
	await expect(page).toHaveURL(/station=611/);
	await expect(page.locator('.active-page .station-name-button h1')).toContainText('Times Sq-42 St');
	await page.goBack();
	await expect(page.locator('.transfer-view')).toContainText('Transfer predictions unavailable');
});

test('v5 settings files preview transfer filters, older files and device records migrate to shared mode', async ({ page }) => {
	const legacy: any = defaults(); delete legacy.transfers; legacy.theme = 'night';
	await seed(page, legacy);
	await page.goto('./?station=602');
	await page.getByRole('button', { name: 'Open settings' }).click();
	await expect(page.getByRole('alert')).toHaveCount(0);
	await expect(page.getByRole('checkbox', { name: 'Save transfer filters separately' })).not.toBeChecked();
	const v5 = readFileSync(new URL('../fixtures/transfers.nerds', import.meta.url));
	await page.getByLabel('Import settings file').setInputFiles({ name: 'transfers.nerds', mimeType: 'application/json', buffer: v5 });
	const preview = page.getByRole('region', { name: 'Import preview' });
	await expect(preview).toContainText('Transfer filters · Save transfer filters separately');
	await expect(preview).toContainText('Transfer filters · Stations · 14 St-Union Sq');
	await page.getByRole('button', { name: 'Replace settings', exact: true }).click();
	await expect(page.getByRole('checkbox', { name: 'Save transfer filters separately' })).toBeChecked();
	const download = page.waitForEvent('download');
	await page.getByRole('button', { name: 'Export settings', exact: true }).click();
	const exported = decodeNerds(readFileSync((await (await download).path())!, 'utf8'));
	expect(exported.version).toBe(6);
	expect(exported.settings).toEqual(decodeNerds(v5.toString()).settings);
	const v4 = readFileSync(new URL('../fixtures/combined-stations.nerds', import.meta.url));
	await page.getByLabel('Import settings file').setInputFiles({ name: 'combined.nerds', mimeType: 'application/json', buffer: v4 });
	await page.getByRole('button', { name: 'Replace settings', exact: true }).click();
	await expect(page.getByRole('checkbox', { name: 'Save transfer filters separately' })).not.toBeChecked();
	expect((await stored(page)).transfers).toEqual({ separateFilters: false, stations: {} });
});
