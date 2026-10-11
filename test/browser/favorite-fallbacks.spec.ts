import { test as base, expect, type Page } from '@playwright/test';
import { defaults, type Settings } from '../../shared/settings';

const test = base.extend({ serviceWorkers: 'block' });
const now = Date.parse('2026-09-06T00:59:40Z') / 1000;

test.beforeEach(async ({ page }) => {
	await page.clock.install({ time: new Date(now * 1000) });
});
test.afterEach(async ({ page }) => { await page.unrouteAll({ behavior: 'wait' }); });

async function seed(page: Page, settings: Settings) {
	await page.addInitScript(settings => {
		localStorage.setItem('sfn:settings:v1', JSON.stringify({ settings, lastStation: '602' }));
	}, settings);
}

async function stationFixture(page: Page) {
	const stations = [
		{ id: '602', name: 'Saved station', lat: 0.02 },
		{ id: '617', name: 'Closest station', lat: 0.001 },
	].map(station => ({ ...station, lon: 0, borough: 'M', routes: [], parts: [] }));
	await page.route('**/api/v1/stations', route => route.fulfill({ json: stations }));
	await page.route('**/api/v1/stations/*/board', route => route.fulfill({ json: {
		station: stations.find(station => route.request().url().includes('/' + station.id + '/')),
		departures: [], sources: [], alerts: [], generatedAt: now,
	} }));
}

for (const fix of ['denied', 'unavailable', 'stale'] as const) {
	test(`${fix} startup GPS preserves a valid saved station`, async ({ page }) => {
		const settings = defaults(); settings.stationSelection.mode = 'closest';
		await seed(page, settings); await stationFixture(page);
		await page.addInitScript(fix => {
			navigator.geolocation.getCurrentPosition = (ok, fail) => {
				(window as any).locationRequested = true;
				if (fix === 'stale') ok({ coords: { latitude: 0, longitude: 0 }, timestamp: Date.now() - 301000 } as GeolocationPosition);
				else fail?.({ code: fix === 'denied' ? 1 : 2, message: fix } as GeolocationPositionError);
			};
		}, fix);
		await page.goto('./');
		await expect.poll(() => page.evaluate(() => (window as any).locationRequested)).toBe(true);
		await page.clock.runFor(1000);
		await expect(page.locator('h1')).toHaveText('Saved station');
		expect(await page.evaluate(() => JSON.parse(localStorage.getItem('sfn:settings:v1')!).lastStation)).toBe('602');
		expect(new URL(page.url()).searchParams.get('station')).toBeNull();
	});
}

test('changing closest mode in Settings does not restart startup navigation on a no-favorites visit', async ({ page }) => {
	await seed(page, defaults()); await stationFixture(page);
	await page.addInitScript(() => {
		navigator.geolocation.getCurrentPosition = ok => ok({ coords: { latitude: 0, longitude: 0 }, timestamp: Date.now() } as GeolocationPosition);
	});
	await page.goto('./'); await expect(page.locator('h1')).toHaveText('Saved station');
	await page.getByRole('button', { name: 'Open settings' }).click();
	await page.getByLabel('App station selection', { exact: true }).selectOption('closest');
	await expect(page.getByLabel('App station selection', { exact: true })).toHaveValue('closest');
	await page.clock.runFor(1000);
	await expect(page.locator('dialog')).toBeVisible();
	await expect(page.locator('h1')).toHaveText('Saved station');
	expect(await page.evaluate(() => JSON.parse(localStorage.getItem('sfn:settings:v1')!).lastStation)).toBe('602');
	expect(new URL(page.url()).searchParams.get('station')).toBeNull();
});

for (const failure of ['connection failure', 'offline event'] as const) {
	test(`fresh matching consist loses favorite highlight after ${failure}`, async ({ page }) => {
		const settings = defaults();
		settings.trainFavorites.consists = [['nyct:R211A:4148', 'nyct:R211A:4149']];
		await seed(page, settings);
		const board = await (await page.request.get('./api/v1/stations/602/board')).json();
		board.departures.forEach((row: any) => {
			row.consist = { cars: [{ number: '4149', type: 'R211A' }, { number: '4148', type: 'R211A' }], updatedAt: now, fetchedAt: now, source: 'helium' };
		});
		let fail = false;
		await page.route('**/api/v1/stations/602/board', route => fail ? route.abort('failed') : route.fulfill({ json: board }));
		await page.goto('./?station=602');
		const first = page.locator('.train-row').first();
		await expect(first).toHaveClass(/favorite-train/);
		await expect(first).toHaveAccessibleName(/Favorite consist/);
		const rows = await page.locator('.train-row').count();
		if (failure === 'connection failure') {
			fail = true;
			await page.getByRole('button', { name: 'Refresh departures' }).click();
			await expect(page.getByText('Feed connection interrupted. Retrying…', { exact: true })).toBeVisible();
		} else {
			// Exercise the app's offline listener without WebKit's network-emulation issue.
			await page.evaluate(() => {
				Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false });
				window.dispatchEvent(new Event('offline'));
			});
			await expect(page.getByText('Offline · showing your last saved board', { exact: true })).toBeVisible();
		}
		await expect(page.locator('.train-row')).toHaveCount(rows);
		await expect(page.locator('.favorite-train')).toHaveCount(0);
		await expect(first).not.toHaveAccessibleName(/Favorite consist|Favorite cars/);
		await expect(page.locator('.favorite-train-label')).toHaveCount(0);
	});
}
