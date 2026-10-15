import test from 'node:test';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { defaults, validateSettings, encodeNerds, decodeNerds, mergeSettings } from '../shared/settings';

const id = 'combined:6d9542db-9ab7-422e-9548-fd66c1d4a384';
test('combined stations and hidden routes survive v4 exports and migrate older settings', () => {
	const settings = defaults();
	assert.deepEqual(settings.combinedStations, {});
	assert.deepEqual(settings.hiddenRoutes, []);
	settings.combinedStations[id] = { name: 'Downtown', stationIDs: ['628', '624', '328'] };
	settings.hiddenRoutes = ['R', '1'];
	const file = decodeNerds(encodeNerds(settings, id));
	assert.equal(file.version, 5);
	assert.deepEqual(file.settings, validateSettings(settings));
	const old = JSON.parse(encodeNerds(defaults(), '602'));
	old.version = 3; delete old.settings.combinedStations; delete old.settings.hiddenRoutes; delete old.settings.transfers;
	assert.deepEqual(decodeNerds(JSON.stringify(old)).settings.combinedStations, {});
	assert.deepEqual(decodeNerds(JSON.stringify(old)).settings.hiddenRoutes, []);
	old.version = 4;
	assert.throws(() => decodeNerds(JSON.stringify(old)));
});

test('invalid or recursive groups cannot replace settings and unknown real stations are portable', () => {
	for (const group of [{ name: '', stationIDs: ['628', '624'] }, { name: '   ', stationIDs: ['628', '624'] }, { name: 'Name', stationIDs: ['628'] }, { name: 'Name', stationIDs: ['628', '628'] }, { name: 'Name', stationIDs: ['628', id] }]) {
		assert.throws(() => validateSettings({ ...defaults(), combinedStations: { [id]: group } }));
	}
	assert.throws(() => validateSettings({ ...defaults(), combinedStations: { '628': { name: 'Bad ID', stationIDs: ['628', '624'] } } }));
	const settings = validateSettings({ ...defaults(), combinedStations: { [id]: { name: 'Future', stationIDs: ['future:station', '628'] } } });
	assert.ok(settings.combinedStations[id].stationIDs.includes('future:station'));
});

test('independent line toggles merge while group deletion versus editing stays explicit', () => {
	const base = defaults(), local = defaults(), remote = defaults();
	local.hiddenRoutes = ['A']; remote.hiddenRoutes = ['C'];
	assert.deepEqual(mergeSettings(base, local, remote).settings.hiddenRoutes, ['A', 'C']);
	base.combinedStations[id] = { name: 'Downtown', stationIDs: ['628', '624'] };
	remote.combinedStations[id] = { name: 'Renamed', stationIDs: ['628', '624'] };
	const merged = mergeSettings(base, local, remote);
	assert.ok(merged.conflicts.some(c => c.path.includes(id)));
});

test('shared v4 fixture is identical across clients and round trips every preference', () => {
	const text = readFileSync(new URL('./fixtures/combined-stations.nerds', import.meta.url), 'utf8');
	assert.equal(text, readFileSync(new URL('../ios/TransitCore/Tests/TransitCoreTests/Fixtures/combined-stations.nerds', import.meta.url), 'utf8'));
	const file = decodeNerds(text);
	assert.equal(file.lastStation, id);
	assert.equal(file.settings.combinedStations[id].stationIDs.length, 4);
	assert.deepEqual(file.settings.hiddenRoutes, ['A', 'NJT-NLR']);
	assert.deepEqual(decodeNerds(encodeNerds(file.settings, file.lastStation)).settings, file.settings);
});
