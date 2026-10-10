import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../server/index';
import { TransitService } from '../server/service';
import type { SourceState } from '../shared/types';

const now = 1_800_000_000;
const endpoint = '/subwaysForNerds/api/v1/health';

test('health separates successful alert polling from snapshot freshness', async t => {
	t.mock.method(Date, 'now', () => now * 1000);
	const service = new TransitService();
	for (const slot of service.slots.values()) {
		if (slot.state.id === 'subway-alerts') continue;
		slot.state = { id: slot.state.id, timestamp: now - 10, fetchedAt: now - 5, error: null };
	}
	// A successful fetch of an unchanged, empty snapshot is still available.
	service.accept('subway-alerts', { header: { timestamp: now - 1084 }, entity: [] }, now - 80);
	service.accept('subway-alerts', { header: { timestamp: now - 1084 }, entity: [] }, now - 20);
	const app = await createServer(service);
	t.after(() => app.close());
	const response = await app.inject(endpoint);
	assert.equal(response.statusCode, 200);
	const health = response.json();
	assert.equal(health.status, 'ok');
	assert.deepEqual(health.arrivals, { status: 'ok' });
	assert.deepEqual(health.alerts, { status: 'ok', freshness: 'uncertain' });
	assert.deepEqual(health.feeds.find((s: SourceState) => s.id === 'subway-alerts'), {
		id: 'subway-alerts', timestamp: now - 1084, fetchedAt: now - 20, error: null, age: 1084, fetchAge: 20,
	});
	assert.equal(health.feeds.length, 9);
	assert.equal(health.stationCount, service.catalog.length);
});

const cases: { name: string; id: string; state: Partial<SourceState>; status: string; arrivals: string; alerts: string; freshness: string }[] = [
	{ name: 'fresh feeds', id: 'subway-alerts', state: {}, status: 'ok', arrivals: 'ok', alerts: 'ok', freshness: 'live' },
	{ name: 'alert snapshot at the freshness boundary', id: 'subway-alerts', state: { timestamp: now - 90 }, status: 'ok', arrivals: 'ok', alerts: 'ok', freshness: 'live' },
	{ name: 'alert snapshot past the freshness boundary', id: 'subway-alerts', state: { timestamp: now - 91 }, status: 'ok', arrivals: 'ok', alerts: 'ok', freshness: 'uncertain' },
	{ name: 'alert polling at two polling intervals', id: 'subway-alerts', state: { fetchedAt: now - 120 }, status: 'ok', arrivals: 'ok', alerts: 'ok', freshness: 'live' },
	{ name: 'stalled alert polling despite a recent snapshot', id: 'subway-alerts', state: { fetchedAt: now - 121 }, status: 'degraded', arrivals: 'ok', alerts: 'degraded', freshness: 'uncertain' },
	{ name: 'failed alert fetch despite recent data', id: 'subway-alerts', state: { error: 'Upstream HTTP 503' }, status: 'degraded', arrivals: 'ok', alerts: 'degraded', freshness: 'uncertain' },
	{ name: 'alerts without a successful fetch', id: 'subway-alerts', state: { fetchedAt: null }, status: 'degraded', arrivals: 'ok', alerts: 'degraded', freshness: 'uncertain' },
	{ name: 'alerts without a snapshot', id: 'subway-alerts', state: { timestamp: null }, status: 'degraded', arrivals: 'ok', alerts: 'degraded', freshness: 'uncertain' },
	{ name: 'arrival snapshot at the freshness boundary', id: 'gtfs', state: { timestamp: now - 90 }, status: 'ok', arrivals: 'ok', alerts: 'ok', freshness: 'live' },
	{ name: 'stale arrival snapshot despite successful polling', id: 'gtfs', state: { timestamp: now - 91 }, status: 'degraded', arrivals: 'degraded', alerts: 'ok', freshness: 'live' },
	{ name: 'failed arrival fetch despite recent data', id: 'gtfs', state: { error: 'Network failure' }, status: 'degraded', arrivals: 'degraded', alerts: 'ok', freshness: 'live' },
	{ name: 'missing arrival snapshot', id: 'gtfs', state: { timestamp: null }, status: 'degraded', arrivals: 'degraded', alerts: 'ok', freshness: 'live' },
];

for (const scenario of cases) test(`health reports ${scenario.name}`, async t => {
	t.mock.method(Date, 'now', () => now * 1000);
	const service = new TransitService();
	for (const slot of service.slots.values()) slot.state = { id: slot.state.id, timestamp: now - 10, fetchedAt: now - 5, error: null };
	Object.assign(service.slots.get(scenario.id)!.state, scenario.state);
	const app = await createServer(service);
	t.after(() => app.close());
	const health = (await app.inject(endpoint)).json();
	assert.equal(health.status, scenario.status);
	assert.deepEqual(health.arrivals, { status: scenario.arrivals });
	assert.deepEqual(health.alerts, { status: scenario.alerts, freshness: scenario.freshness });
	const feed = health.feeds.find((s: SourceState) => s.id === scenario.id);
	assert.equal(feed.age, feed.timestamp === null ? null : now - feed.timestamp);
	assert.equal(feed.fetchAge, feed.fetchedAt === null ? null : now - feed.fetchedAt);
	assert.deepEqual((await app.inject('/healthz')).json(), { status: 'ok' });
});

test('health reports unavailable feeds during startup without fetching upstream', async t => {
	const service = new TransitService({ fetcher: async () => { throw new Error('Health must not fetch upstream'); } });
	const app = await createServer(service);
	t.after(() => app.close());
	const health = (await app.inject(endpoint)).json();
	assert.equal(health.status, 'degraded');
	assert.deepEqual(health.arrivals, { status: 'degraded' });
	assert.deepEqual(health.alerts, { status: 'degraded', freshness: 'uncertain' });
	assert.ok(health.feeds.every((s: any) => s.age === null && s.fetchAge === null));
});
