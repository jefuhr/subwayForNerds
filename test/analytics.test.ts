import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Fastify from 'fastify';
import { AnalyticsStore } from '../server/analytics-store.mjs';
import { registerAnalytics } from '../server/analytics';
import type { AnalyticsEvent } from '../shared/analytics';
const event = (patch: Partial<AnalyticsEvent> = {}): AnalyticsEvent => ({ id: randomUUID(), browser: randomUUID(), session: randomUUID(), name: 'session_start', device: 'phone', referrer: '', ...patch });
test('analytics deduplicates deliveries and sessions, computes returning browsers and New York days, and retains only one year', () => {
  const now = Date.parse('2026-09-07T04:01:00Z'), store = new AnalyticsStore(':memory:', now - 100000);
  try {
    const first = event();
    store.record([first, first], now - 120000);
    store.record([event({ browser: first.browser, session: first.session })], now - 60000);
    store.record([event({ browser: first.browser }), event({ name: 'station_view', station: '602', browser: first.browser }), event({ name: 'line', station: '602', browser: first.browser })], now);
    const today = store.stats('today', now);
    assert.equal(today.visits, 1); assert.equal(today.returning, 1); assert.equal(today.browsers, 1); assert.equal(today.views, 1);
    assert.deepEqual(today.daily.map(row => ({ ...row })), [{ date: '2026-09-07', visits: 1, views: 1 }]);
    assert.equal(store.stats('7d', now).visits, 2);
    assert.equal(today.interactions[0].label, 'line');
    assert.ok(!JSON.stringify(today).includes(first.browser)); assert.ok(!JSON.stringify(today).includes(first.session));
    store.record([event()], now - 366 * 86400000);
    assert.equal(store.stats('365d', now).visits, 2);
    assert.equal(store.stats('365d', now + 366 * 86400000).visits, 0);
  } finally { store.close(); }
});
test('analytics calendar ranges span DST correctly', () => {
  const now = Date.parse('2026-03-09T04:01:00Z'), store = new AnalyticsStore(':memory:', now);
  try { store.record([event()], Date.parse('2026-03-08T05:01:00Z')); assert.equal(store.stats('today', now).visits, 0); assert.equal(store.stats('7d', now).visits, 1); assert.equal(store.stats('7d', now).daily.length, 7); } finally { store.close(); }
});
test('analytics API validates fields, bounds batches and rates, exposes aggregates, and isolates failed databases', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'sfn-analytics-'));
  const previous = process.env.STATE_DIR; process.env.STATE_DIR = directory;
  const app = Fastify(); registerAnalytics(app, '/api', [{ id: '602', name: 'Union Sq' }]);
  const post = (events: unknown[]) => app.inject({ method: 'POST', url: '/api/analytics/events', payload: { events } });
  try {
    const e = event(); assert.equal((await post([e, e])).statusCode, 204);
    assert.equal((await post([event({ name: 'station_view', station: '602' })])).statusCode, 204);
    for (const invalid of [{ ...e, ip: '1.2.3.4' }, { ...e, referrer: 'https://example.com/private?q=secret' }, { ...e, name: 'search' }, { ...e, station: 'bad' }, { ...e, id: 'bad' }]) assert.equal((await post([invalid])).statusCode, 400);
    assert.equal((await post(Array(21).fill(e))).statusCode, 400);
    const response = await app.inject('/api/stats?range=today'); assert.equal(response.statusCode, 200);
    assert.equal(response.json().visits, 1); assert.equal(response.json().stations[0].label, 'Union Sq');
    assert.ok(!response.body.includes(e.browser)); assert.ok(!response.body.includes(e.session));
    assert.equal((await app.inject('/api/stats?range=invalid')).statusCode, 400);
    let status = 0; for (let i = 0; i < 61; i++) status = (await post([e])).statusCode;
    assert.equal(status, 429);
  } finally { await app.close(); }
  process.env.STATE_DIR = '/dev/null/unusable';
  const broken = Fastify(); registerAnalytics(broken, '/api', []); broken.get('/healthz', () => ({ status: 'ok' }));
  try { assert.equal((await broken.inject('/api/stats')).statusCode, 503); assert.equal((await broken.inject('/healthz')).statusCode, 200); }
  finally { await broken.close(); if (previous === undefined) delete process.env.STATE_DIR; else process.env.STATE_DIR = previous; await rm(directory, { recursive: true, force: true }); }
});
