import { test as base, expect, type Page } from '@playwright/test';
import rows from '../../data/njt-light-rail-stations.json' with { type: 'json' };
import { NJT_LINES } from '../../shared/njt';
import type { Board, Departure, SourceState, Station, Train, VehiclePosition } from '../../shared/types';

const test = base.extend({ serviceWorkers: 'block' });
const now = Date.parse('2026-10-12T14:00:00Z') / 1000;
const systems = ['NJT-HBLR', 'NJT-NLR', 'NJT-RIVER'];
const stations: Station[] = systems.map(route => {
	const row = rows.find(row => row.route === route && (route !== 'NJT-HBLR' || row.code === '30829'))!;
	const id = `njt-lr-${row.code}`, name = `${row.name} (${NJT_LINES[route].label})`;
	return { id, name, borough: 'NJ', municipality: row.municipality, routes: [route], lat: row.lat, lon: row.lon, departureMode: 'external',
		parts: [{ id, stationId: row.code, name, line: NJT_LINES[route].name, routes: [route], lat: row.lat, lon: row.lon, ada: '', adaNotes: '', north: 'Northbound', south: 'Southbound' }] };
});
const source = (id: string, age = 0): SourceState => ({ id, timestamp: now - age, fetchedAt: now, error: null, staleAfter: 60 });
function fixture(station = stations[0]): Board {
	const position: VehiclePosition = { id: `gps-${station.id}`, provider: 'njt-bus-g2', vehicleId: '2011', route: station.routes[0],
		tripId: 'trip-1', lat: station.lat, lon: station.lon, stopName: 'Reported GPS stop', timestamp: now, fetchedAt: now };
	const departure: Departure = { key: `departure-${station.id}`, tripKey: `trip-${station.id}`, route: station.routes[0], destination: 'Fixture terminal', direction: 'NORTH',
		stopId: station.parts[0].stationId, partId: station.id, area: station.name, time: now + 600, arrival: now + 600,
		pattern: 'Reported stops', patternSource: 'inferred', location: 'Location not reported', stopsAway: 2, feed: 'njt-bus-g2', timestamp: now, staleAfter: 60,
		alerts: [], onward: [], vehiclePosition: position };
	const predictions = source('njt-predictions'), positions = source('njt-positions');
	return { station, generatedAt: now, sources: [predictions, positions], departures: [departure], alerts: [], vehiclePositions: [position],
		njt: { configured: true, predictions, positions, cacheError: null } };
}
async function mock(page: Page, board: Board) {
	await page.clock.setFixedTime(new Date(now * 1000));
	await page.route('**/api/v1/stations', route => route.fulfill({ json: stations }));
	await page.route('**/api/v1/stations/*/board', route => route.fulfill({ json: board }));
	await page.route('**/api/v1/trips?*', route => {
		const d = board.departures[0];
		const train: Train = { key: d.tripKey, feed: d.feed, tripId: 'trip-1', route: d.route, destination: d.destination, direction: d.direction,
			timestamp: d.timestamp, staleAfter: d.staleAfter, vehiclePosition: d.vehiclePosition, alerts: [],
			stops: [{ id: d.stopId, stationId: board.station.id, name: board.station.name, arrival: d.arrival, departure: d.time }] };
		return route.fulfill({ json: { train, raw: {} } });
	});
}
async function officialLinks(page: Page) {
	const active = page.locator('.active-page');
	await expect(active.getByRole('link', { name: 'NJ Transit departures' })).toHaveAttribute('href', 'https://www.njtransit.com/dv-to');
	await expect(active.getByRole('link', { name: 'Light rail schedules' })).toHaveAttribute('href', 'https://www.njtransit.com/light-rail-to');
	await expect(active.getByRole('link', { name: 'Service alerts' })).toHaveAttribute('href', 'https://www.njtransit.com/travel-alerts-to');
}
async function noOverflow(page: Page) {
	expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
}
test.afterEach(async ({ page }) => { await page.unrouteAll({ behavior: 'wait' }); });

for (const station of stations) test(`${station.routes[0]} shows connected predictions, matching GPS, details and official links`, async ({ page }, testInfo) => {
	const board = fixture(station);
	board.vehiclePositions!.push({ ...board.vehiclePositions![0], id: 'other-system', vehicleId: '9999', route: systems.find(route => route !== station.routes[0])! });
	await mock(page, board);
	await page.goto(`./?station=${station.id}`);
	const active = page.locator('.active-page');
	await expect(active.locator('h1')).toHaveText(station.name);
	await expect(active.locator('.station-kicker .status-pill')).toHaveText('LIVE ARRIVALS');
	await expect(active.locator('.train-row')).toHaveCount(1);
	await expect(active.locator('.train-time strong')).toHaveText('10');
	await expect(active.locator('.njt-position')).toHaveCount(1);
	await expect(active.locator('.njt-position')).toContainText('2011');
	await expect(active.locator('.njt-position')).not.toContainText('9999');
	await officialLinks(page); await noOverflow(page);
	await page.screenshot({ path: testInfo.outputPath('connected-board.png'), fullPage: true });
	await active.locator('.train-row').click();
	await expect(page.locator('.detail-summary .status-pill')).toContainText('live');
	await expect(page.locator('.fact-grid')).toContainText('Reported GPS stop');
	expect(await page.locator('dialog').evaluate(el => el.scrollWidth <= el.clientWidth)).toBe(true);
});

test('a stale GPS report never blocks a fresh arrival and expires without stops-away claims', async ({ page }) => {
	const board = fixture();
	board.vehiclePositions![0].timestamp = now - 90;
	await mock(page, board); await page.goto(`./?station=${board.station.id}`);
	await expect(page.locator('.station-kicker .status-pill')).toHaveText('LIVE ARRIVALS');
	await expect(page.locator('.train-time strong')).toHaveText('10');
	await expect(page.locator('.train-location')).toContainText('Last known: Reported GPS stop');
	await expect(page.locator('.njt-position')).toContainText('Last known');
	await page.locator('.train-row').click();
	await expect(page.locator('.fact-grid')).toContainText('Last known: Reported GPS stop');
	await page.keyboard.press('Escape');
	await page.clock.setFixedTime(new Date((now + 211) * 1000));
	await expect(page.locator('.njt-position')).toHaveCount(0);
	await expect(page.locator('.train-location')).not.toContainText('stops away');
	await expect(page.locator('.train-location')).not.toContainText('Reported GPS stop');
});

test('fresh predictions remain usable without a GPS match', async ({ page }) => {
	const board = fixture(); delete board.departures[0].vehiclePosition; board.vehiclePositions = [];
	await mock(page, board); await page.goto(`./?station=${board.station.id}`);
	await expect(page.locator('.station-kicker .status-pill')).toHaveText('LIVE ARRIVALS');
	await expect(page.locator('.train-time strong')).toHaveText('10');
	await expect(page.locator('.train-location')).toContainText('GPS position not reported');
	await expect(page.locator('.train-location')).not.toContainText('stops away');
});

for (const gps of [true, false]) test(`an empty fresh prediction feed stays honest ${gps ? 'with GPS' : 'without GPS'}`, async ({ page }, testInfo) => {
	const board = fixture(); board.departures = [];
	if (gps) { delete board.vehiclePositions![0].stopName; board.vehiclePositions![0].stopId = board.station.parts[0].stationId; }
	else board.vehiclePositions = [];
	await mock(page, board); await page.goto(`./?station=${board.station.id}`);
	await expect(page.locator('.station-kicker .status-pill')).toHaveText('NO LIVE PREDICTIONS');
	await expect(page.locator('.station-kicker .status-pill')).not.toHaveClass(/live/);
	await expect(page.getByRole('heading', { name: 'No live predictions reported for this station' })).toBeVisible();
	await expect(page.locator('.train-row')).toHaveCount(0);
	await expect(page.getByRole('button', { name: 'Refresh departures' })).toBeVisible();
	await expect(page.locator('.njt-position')).toHaveCount(gps ? 1 : 0);
	if (gps) await expect(page.locator('.njt-position')).toContainText(`${board.station.lat.toFixed(5)}, ${board.station.lon.toFixed(5)}`);
	await officialLinks(page); await noOverflow(page);
	await page.screenshot({ path: testInfo.outputPath('empty-board.png'), fullPage: true });
});

test('NJT predictions and details age at 60 seconds while fresh GPS cannot make arrivals live', async ({ page }) => {
	const board = fixture(); board.departures[0].timestamp = now - 61; board.njt!.predictions.timestamp = now - 61;
	await mock(page, board); await page.goto(`./?station=${board.station.id}`);
	await expect(page.locator('.station-kicker .status-pill')).toHaveText('AWAITING LIVE DATA');
	await expect(page.locator('.train-time')).toContainText('last estimate');
	await expect(page.locator('.njt-position')).toContainText('GPS report');
	await expect(page.locator('.njt-position')).not.toContainText('Last known');
	await page.locator('.train-row').click();
	await expect(page.locator('.detail-summary .status-pill')).toContainText('stale');
});

test('NJT transfer origins and connecting predictions use their separate freshness limits', async ({ page }) => {
	const board = fixture(); await mock(page, board);
	let originAge = 0;
	await page.route('**/api/v1/trips/transfers?*', route => route.fulfill({ json: {
		originTimestamp: now - originAge, originStaleAfter: 60, station: board.station, arrival: now + 600, basis: 'arrival',
		connections: [
			{ ...board.departures[0], key: 'fresh', destination: 'Fresh connection', gap: 120, basis: 'departure', time: now + 720 },
			{ ...board.departures[0], key: 'stale', destination: 'Stale connection', timestamp: now - 61, gap: 120, basis: 'departure', time: now + 720 },
		], sources: [board.njt!.predictions],
	} }));
	await page.goto(`./?station=${board.station.id}`);
	await page.locator('.train-row').click(); await page.locator('.stop-link').click();
	await expect(page.locator('.transfer-row')).toHaveCount(1);
	await expect(page.locator('.transfer-row')).toContainText('Fresh connection');
	await page.getByRole('button', { name: 'Back to train' }).click();
	originAge = 61; await page.locator('.stop-link').click();
	await expect(page.locator('.transfer-view')).toContainText('Predictions are stale');
	await expect(page.locator('.transfer-row')).toHaveCount(0);
});

test('cached NJT data uses last estimates, ages GPS from its source clock and retains expired data on disk', async ({ page }, testInfo) => {
	const board = fixture();
	await mock(page, board); await page.goto(`./?station=${board.station.id}`);
	await expect(page.locator('.train-time strong')).toHaveText('10');
	await page.evaluate(() => {
		Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false });
		window.dispatchEvent(new Event('offline'));
	});
	await expect(page.locator('.station-kicker .status-pill')).toHaveText('CACHED BOARD');
	await expect(page.locator('.train-time')).toContainText('last estimate');
	await expect(page.locator('.njt-position')).toContainText('Last known');
	// Reload from the browser's saved Board rather than only testing in-memory state.
	await page.addInitScript(() => { Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => false }); });
	await page.reload();
	await expect(page.locator('.station-kicker .status-pill')).toHaveText('CACHED BOARD');
	await expect(page.locator('.train-time')).toContainText('last estimate');
	await page.clock.setFixedTime(new Date((now + 61) * 1000));
	await expect(page.locator('.njt-position')).toContainText('1m ago');
	await page.clock.setFixedTime(new Date((now + 301) * 1000));
	await expect(page.locator('.njt-position')).toHaveCount(0);
	await expect(page.locator('.train-location')).not.toContainText('stops away');
	const saved = await page.evaluate(id => JSON.parse(localStorage.getItem(`sfn:board:${id}`)!), board.station.id);
	expect(saved.vehiclePositions).toHaveLength(1); expect(saved.vehiclePositions[0].timestamp).toBe(now);
	await noOverflow(page);
	await page.screenshot({ path: testInfo.outputPath('cached-aged-board.png'), fullPage: true });
});

test('configured boards preserve station favorites and station search', async ({ page }) => {
	const board = fixture(); await mock(page, board); await page.goto(`./?station=${board.station.id}`);
	const active = page.locator('.active-page');
	await active.getByRole('button', { name: 'Favorite this station', exact: true }).click();
	await expect(active.getByRole('button', { name: 'Remove favorite station', exact: true })).toBeVisible();
	await active.locator('.station-name-button').click();
	await page.getByRole('textbox', { name: 'Search stations' }).fill('River LINE');
	await expect(page.locator('.station-result')).toHaveCount(1);
	await noOverflow(page);
});

test('explicitly unconfigured NJT boards retain the external directory', async ({ page }) => {
	const board = fixture(); board.njt!.configured = false; board.departures = []; board.vehiclePositions = [];
	await mock(page, board); await page.goto(`./?station=${board.station.id}`);
	await expect(page.locator('.station-kicker .status-pill')).toHaveText('STATION DIRECTORY');
	await expect(page.getByRole('button', { name: 'Refresh departures' })).toHaveCount(0);
	await officialLinks(page);
});
