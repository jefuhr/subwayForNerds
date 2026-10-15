import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { defaults, defaultTransfers, decodeNerds, encodeNerds, mergeSettings, settingsChanges, validateSettings } from '../shared/settings';
import { filterTransfers, lineVisible, seedTransferFilter, transferFilter, transferRouteChoices, withTransferFilter } from '../shared/transfer-filters';
import type { Station } from '../shared/types';

const fixture = () => readFileSync(new URL('./fixtures/transfers.nerds', import.meta.url), 'utf8');

test('transfer filters default to shared mode and legacy device or account settings migrate', () => {
	assert.deepEqual(defaults().transfers, { separateFilters: false, stations: {} });
	assert.deepEqual(defaultTransfers(), defaults().transfers);
	const legacy: any = defaults(); delete legacy.transfers;
	assert.deepEqual(validateSettings(legacy).transfers, defaultTransfers());
});

test('v5 exports require transfers and v1-v4 files import in shared mode', () => {
	const settings = defaults();
	settings.transfers = { separateFilters: true, stations: { '602': { direction: 'SOUTH', routes: ['6', '4'] } } };
	const exported = JSON.parse(encodeNerds(settings, '602'));
	assert.equal(exported.version, 5);
	assert.deepEqual(decodeNerds(JSON.stringify(exported)).settings.transfers, { separateFilters: true, stations: { '602': { direction: 'SOUTH', routes: ['4', '6'] } } });
	const missing = structuredClone(exported); delete missing.settings.transfers;
	assert.throws(() => decodeNerds(JSON.stringify(missing)));
	for (const version of [1, 2, 3, 4]) {
		const older = structuredClone(missing); older.version = version;
		if (version < 4) { delete older.settings.combinedStations; delete older.settings.hiddenRoutes; }
		if (version < 3) delete older.settings.offline;
		assert.deepEqual(decodeNerds(JSON.stringify(older)).settings.transfers, defaultTransfers(), 'v' + version);
		// Older portable versions cannot carry transfer filters.
		older.settings.transfers = defaultTransfers();
		assert.throws(() => decodeNerds(JSON.stringify(older)), Error, 'v' + version + ' with transfers');
	}
	assert.throws(() => decodeNerds(encodeNerds(defaults(), '602').replace('"version": 5', '"version": 6')), /not supported/);
});

test('transfer entries follow station filter limits and never carry a board view', () => {
	const entry = (value: unknown) => validateSettings({ ...defaults(), transfers: { separateFilters: true, stations: { '602': value } } });
	assert.deepEqual(entry({ direction: 'TO_NJ', routes: [] }).transfers.stations['602'], { direction: 'TO_NJ', routes: [] });
	for (const bad of [{ direction: 'ALL', routes: [], view: 'track' }, { direction: 'EAST', routes: [] }, { direction: 'ALL' }, { direction: 'ALL', routes: ['A', 'A'] }, { direction: 'ALL', routes: [''] }, { direction: 'ALL', routes: Array.from({ length: 129 }, (_, i) => 'R' + i) }, null, []]) {
		assert.throws(() => entry(bad), Error, JSON.stringify(bad));
	}
	for (const transfers of [{ separateFilters: 'true', stations: {} }, { separateFilters: false }, { separateFilters: false, stations: {}, extra: 1 }, { separateFilters: false, stations: JSON.parse('{"__proto__":{"direction":"ALL","routes":[]}}') }, null]) {
		assert.throws(() => validateSettings({ ...defaults(), transfers }), Error, JSON.stringify(transfers));
	}
	const many = Object.fromEntries(Array.from({ length: 2001 }, (_, i) => ['s' + i, { direction: 'ALL', routes: [] }]));
	assert.throws(() => validateSettings({ ...defaults(), transfers: { separateFilters: false, stations: many } }));
});

test('canonical v5 fixture round trips every transfer preference', () => {
	const file = decodeNerds(fixture());
	assert.equal(file.version, 5);
	assert.equal(file.settings.transfers.separateFilters, true);
	assert.deepEqual(file.settings.transfers.stations['602'], { direction: 'SOUTH', routes: ['5', '6'] });
	assert.deepEqual(file.settings.transfers.stations['path-wtc'], { direction: 'TO_NJ', routes: [] });
	assert.deepEqual(file.settings.transfers.stations['future:station'], { direction: 'ALL', routes: ['S', 'SIR'] });
	assert.deepEqual(file.settings.stations['602'], { direction: 'NORTH', routes: ['4'], view: 'family' });
	assert.deepEqual(file.settings.hiddenRoutes, ['6X', 'SIR']);
	assert.deepEqual(decodeNerds(encodeNerds(file.settings, file.lastStation)).settings, file.settings);
});

test('transfer filters merge field by field and conflict explicitly', () => {
	const base = defaults(), local = structuredClone(base), remote = structuredClone(base);
	local.transfers.stations['602'] = { direction: 'NORTH', routes: [] };
	remote.transfers.stations['631'] = { direction: 'SOUTH', routes: ['4'] };
	remote.transfers.separateFilters = true;
	const merged = mergeSettings(base, local, remote);
	assert.deepEqual(merged.conflicts, []);
	assert.deepEqual(merged.settings.transfers, { separateFilters: true, stations: { '602': { direction: 'NORTH', routes: [] }, '631': { direction: 'SOUTH', routes: ['4'] } } });
	const both = structuredClone(merged.settings), first = structuredClone(both), second = structuredClone(both);
	first.transfers.stations['602'].direction = 'SOUTH'; second.transfers.stations['602'].direction = 'ALL';
	first.transfers.separateFilters = false;
	const conflict = mergeSettings(both, first, second);
	assert.deepEqual(conflict.conflicts.map(c => c.path), ['/transfers/stations/602/direction']);
	assert.equal(conflict.settings.transfers.separateFilters, false);
	assert.equal(mergeSettings(both, first, second, { '/transfers/stations/602/direction': 'remote' }).settings.transfers.stations['602'].direction, 'ALL');
	const legacyBase: any = defaults(); delete legacyBase.transfers;
	assert.equal(mergeSettings(legacyBase, local, base).settings.transfers.stations['602'].direction, 'NORTH');
	assert.deepEqual(settingsChanges(base, remote).map(c => c.path), ['transfers / separateFilters', 'transfers / stations / 631']);
});

test('shared mode reads and writes the target station board filter while preserving its view', () => {
	let settings = defaults();
	settings.stations['631'] = { direction: 'SOUTH', routes: ['4'], view: 'service' };
	assert.deepEqual(transferFilter(settings, '631'), { direction: 'SOUTH', routes: ['4'] });
	assert.deepEqual(transferFilter(settings, '602'), { direction: 'ALL', routes: [] });
	settings = withTransferFilter(settings, '631', { routes: ['GS', '6'] });
	assert.deepEqual(settings.stations['631'], { direction: 'SOUTH', routes: ['6', 'S'], view: 'service' });
	settings = withTransferFilter(settings, '602', { direction: 'NORTH' });
	assert.deepEqual(settings.stations['602'], { direction: 'NORTH', routes: [], view: 'track' });
	assert.deepEqual(settings.transfers.stations, {});
	assert.equal(seedTransferFilter(settings, '631'), settings, 'shared mode never seeds a separate entry');
});

test('separate mode copies the board filter once, then edits independently and survives toggling', () => {
	let settings = defaults();
	settings.stations['631'] = { direction: 'SOUTH', routes: ['4'], view: 'family' };
	settings.transfers.separateFilters = true;
	assert.deepEqual(transferFilter(settings, '631'), { direction: 'SOUTH', routes: ['4'] });
	settings = seedTransferFilter(settings, '631');
	assert.deepEqual(settings.transfers.stations['631'], { direction: 'SOUTH', routes: ['4'] });
	assert.equal(seedTransferFilter(settings, '631'), settings);
	settings = withTransferFilter(settings, '631', { direction: 'ALL', routes: ['5'] });
	assert.deepEqual(settings.transfers.stations['631'], { direction: 'ALL', routes: ['5'] });
	assert.deepEqual(settings.stations['631'], { direction: 'SOUTH', routes: ['4'], view: 'family' });
	settings = withTransferFilter(settings, '602', { direction: 'NORTH' });
	assert.deepEqual(settings.transfers.stations['602'], { direction: 'NORTH', routes: [] });
	assert.equal(settings.stations['602'], undefined);
	settings = { ...settings, transfers: { ...settings.transfers, separateFilters: false } };
	assert.deepEqual(transferFilter(settings, '631'), { direction: 'SOUTH', routes: ['4'] });
	assert.deepEqual(settings.transfers.stations['631'], { direction: 'ALL', routes: ['5'] }, 'the separate map is retained');
	settings = { ...settings, transfers: { ...settings.transfers, separateFilters: true } };
	assert.deepEqual(transferFilter(settings, '631'), { direction: 'ALL', routes: ['5'] });
	validateSettings(settings);
});

const station: Station = { id: '631', name: 'Grand Central', borough: 'M', lat: 0, lon: 0, routes: ['4', '5', '6', '6X', '7', 'GS'], parts: [] };
const row = (route: string, direction = 'NORTH') => ({ route, direction, key: route + direction }) as any;

test('route choices are stable, alias-normalized and honor hidden lines', () => {
	assert.deepEqual(transferRouteChoices(station, [row('7X'), row('S'), row('4')], []), ['4', '5', '6', '6X', '7', 'S', '7X']);
	assert.deepEqual(transferRouteChoices(station, [], ['6', 'S']), ['4', '5', '7']);
	assert.deepEqual(transferRouteChoices(undefined, [row('SI')], []), ['SIR']);
	assert.ok(!lineVisible('FX', ['F']) && !lineVisible('SI', ['SIR']) && lineVisible('A', ['C']));
});

test('transfer rows match direction, normalized routes and hidden lines without discarding selections', () => {
	const rows = [row('4'), row('4', 'SOUTH'), row('GS'), row('6X'), row('6')];
	assert.deepEqual(filterTransfers(rows, { direction: 'ALL', routes: [] }, []).map(r => r.key), rows.map(r => r.key));
	assert.deepEqual(filterTransfers(rows, { direction: 'SOUTH', routes: [] }, []).map(r => r.key), ['4SOUTH']);
	assert.deepEqual(filterTransfers(rows, { direction: 'ALL', routes: ['S'] }, []).map(r => r.key), ['GSNORTH']);
	assert.deepEqual(filterTransfers(rows, { direction: 'ALL', routes: ['GS'] }, []).map(r => r.key), ['GSNORTH']);
	assert.deepEqual(filterTransfers(rows, { direction: 'ALL', routes: [] }, ['6']).map(r => r.key), ['4NORTH', '4SOUTH', 'GSNORTH']);
	// A hidden selection stays saved but cannot reveal hidden rows.
	assert.deepEqual(filterTransfers(rows, { direction: 'ALL', routes: ['6', '4'] }, ['6']).map(r => r.key), ['4NORTH', '4SOUTH']);
	assert.deepEqual(filterTransfers(rows, { direction: 'ALL', routes: ['6'] }, ['6']), []);
});
