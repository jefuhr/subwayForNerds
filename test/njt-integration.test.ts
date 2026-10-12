import test from 'node:test';
import assert from 'node:assert/strict';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';

test('configured NJT API boards are connected independently of MTA feeds and context', async () => {
	const service = new TransitService({ njtCredentials: { username: 'fixture', password: 'fixture' } });
	service.alerts = [{ id: 'mta-wide', title: 'MTA notice', description: '', routes: [], stops: [], selectors: [], periods: [] }];
	service.refreshBoards();
	const app = await createServer(service);
	try {
		for (const id of ['njt-lr-30829', 'njt-lr-30771', 'njt-lr-30855']) {
			const board = (await app.inject(`/subwaysForNerds/api/v1/stations/${id}/board`)).json();
			assert.equal(board.njt.configured, true);
			assert.equal(board.station.departureMode, undefined);
			assert.deepEqual(board.alerts, []);
			assert.deepEqual(board.departures, []);
			assert.ok(board.sources.every((s: any) => s.id.startsWith('njt-')));
			assert.deepEqual(service.context(id), { entrances: [], equipment: [], outages: [], sources: [] });
		}
		const health = (await app.inject('/subwaysForNerds/api/v1/health')).json();
		assert.ok(health.njt);
		assert.ok(health.feeds.every((s: any) => !s.id.startsWith('njt-')));
	} finally { await app.close(); }
});

test('NJT without configured credentials preserves station-directory behavior', () => {
	const service = new TransitService({ njtCredentials: { username: '', password: '' } });
	service.refreshBoards();
	const board = service.boards.get('njt-lr-30855')!;
	assert.equal(board.station.departureMode, 'external');
	assert.ok(!board.njt?.configured);
	assert.deepEqual(board.sources, []);
});

test('MTA catalog refresh keeps configured NJT stations connected and favorites IDs stable', async () => {
	const { default: rows } = await import('../data/stations.json', { with: { type: 'json' } });
	const socrata = rows.map(r => ({ gtfs_stop_id: r.id, station_id: r.stationId, complex_id: r.complexId, stop_name: r.name, line: r.line, daytime_routes: r.routes.join(' '), gtfs_latitude: String(r.lat), gtfs_longitude: String(r.lon), ada: r.ada, borough: r.borough }));
	const service = new TransitService({ njtCredentials: { username: 'fixture', password: 'fixture' }, fetcher: async () => Response.json(socrata) });
	const tasks: (() => Promise<void>)[] = [];
	service.schedule = task => { tasks.push(task); };
	service.restore = async () => undefined;
	service.persist = async () => {};
	service.startContext();
	await tasks[0]();
	const stations = service.catalog.filter(s => s.id.startsWith('njt-lr-'));
	assert.equal(stations.length, 62);
	assert.ok(stations.every(s => s.departureMode === undefined));
	assert.equal(service.boards.get('njt-lr-30855')!.njt?.configured, true);
});
