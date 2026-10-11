import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { defaults, encodeNerds, decodeNerds, validateSettings, mergeSettings } from '../shared/settings';

test('nerds files round trip native-only preferences and unknown station references', () => {
	const file = decodeNerds(readFileSync(new URL('./fixtures/settings.nerds', import.meta.url), 'utf8'));
	assert.equal(file.settings.widgets.stations['future:station'].view, 'corridor');
	assert.equal(file.settings.widgets.lockScreen.directionOrder, 'uptownLeft');
	assert.deepEqual(decodeNerds(encodeNerds(file.settings, file.lastStation)).settings, file.settings);
});
test('invalid, oversized and unsupported imports fail before replacement', () => {
	for (const text of ['{}', 'null', '{', ' '.repeat(1048577), encodeNerds(defaults(), '602').replace('"version": 2', '"version": 3')]) assert.throws(() => decodeNerds(text));
	const value = defaults(); value.widgets.display.trainsPerDirection = 9;
	assert.throws(() => validateSettings(value));
	assert.throws(() => validateSettings({ ...defaults(), stations: JSON.parse('{"__proto__":{}}') }));
});

test('v2 exports preserve train favorites and independent widget station selection while v1 imports migrate', () => {
	const legacy = decodeNerds(readFileSync(new URL('./fixtures/settings.nerds', import.meta.url), 'utf8'));
	assert.deepEqual(legacy.settings.trainFavorites, { cars: [], consists: [], match: 'exact' });
	assert.deepEqual(legacy.settings.stationSelection, { mode: 'favorite', radiusFeet: 5280 });
	assert.equal(legacy.settings.widgets.stationSelection.followApp, true);
	const settings = legacy.settings;
	settings.trainFavorites = { cars: ['sir:R211S:100'], consists: [['nyct:R160:002', 'nyct:R160:001']], match: 'anyCar' };
	settings.stationSelection = { mode: 'closest', radiusFeet: 1 };
	settings.widgets.stationSelection = { followApp: false, selection: { mode: 'nearbyFavorite', radiusFeet: 26400 } };
	const file = decodeNerds(encodeNerds(settings, 'future:station'));
	assert.equal(file.version, 2);
	assert.deepEqual(file.settings, validateSettings(settings));
	assert.deepEqual(file.settings.trainFavorites.consists, [['nyct:R160:001', 'nyct:R160:002']]);
});

test('malformed train IDs, duplicate consists, partial v2 files and invalid radius cannot replace settings', () => {
	for (const cars of [['001'], ['other:R160:001'], ['nyct:R160:001', 'nyct:R160:001'], ['nyct:R160:\n'], ['nyct:R160A:001'], ['nyct:R160:0\u00851'], ['nyct:R160:0\ufeff1']]) {
		assert.throws(() => validateSettings({ ...defaults(), trainFavorites: { cars, consists: [], match: 'exact' } }));
	}
	for (const consists of [[[]], [['nyct:R160:001', 'nyct:R160:001']], [['nyct:R160:001', 'nyct:R160:002'], ['nyct:R160:002', 'nyct:R160:001']]]) {
		assert.throws(() => validateSettings({ ...defaults(), trainFavorites: { cars: [], consists, match: 'exact' } }));
	}
	for (const radiusFeet of [0, 26401, 1.5, NaN, '5280']) {
		assert.throws(() => validateSettings({ ...defaults(), stationSelection: { mode: 'closest', radiusFeet } }));
	}
	const file = JSON.parse(encodeNerds(defaults(), '602'));
	delete file.settings.stationSelection;
	assert.throws(() => decodeNerds(JSON.stringify(file)));
});

test('train membership merges independently and mode/radius conflicts remain explicit', () => {
	const base = defaults();
	base.trainFavorites.cars = ['nyct:R160:001'];
	base.trainFavorites.consists = [['nyct:R160:001', 'nyct:R160:002']];
	const local = structuredClone(base), remote = structuredClone(base);
	local.trainFavorites.cars = ['sir:R211S:100'];
	remote.trainFavorites.cars.push('nyct:R46:001');
	local.trainFavorites.consists = [];
	remote.trainFavorites.consists.push(['nyct:R46:001', 'nyct:R46:002']);
	local.stationSelection.mode = 'closest'; remote.stationSelection.mode = 'nearbyFavorite';
	local.stationSelection.radiusFeet = 1; remote.stationSelection.radiusFeet = 100;
	const result = mergeSettings(base, local, remote);
	assert.deepEqual(result.settings.trainFavorites.cars, ['nyct:R46:001', 'sir:R211S:100']);
	assert.deepEqual(result.settings.trainFavorites.consists, [['nyct:R46:001', 'nyct:R46:002']]);
	assert.deepEqual(result.conflicts.map(c => c.path), ['/stationSelection/mode', '/stationSelection/radiusFeet']);
	const resolved = mergeSettings(base, local, remote, { '/stationSelection/mode': 'remote', '/stationSelection/radiusFeet': 'local' });
	assert.deepEqual(resolved.settings.stationSelection, { mode: 'nearbyFavorite', radiusFeet: 1 });
	assert.deepEqual(resolved.conflicts, []);
});
test('three-way sync combines independent edits and preserves removals', () => {
	const base = defaults(); base.favorites = ['602', '617'];
	const local = structuredClone(base), remote = structuredClone(base);
	local.favorites = ['617', '611']; remote.favorites.push('607'); remote.theme = 'night';
	const result = mergeSettings(base, local, remote);
	assert.deepEqual(result.settings.favorites, ['617', '607', '611']);
	assert.equal(result.settings.theme, 'night'); assert.deepEqual(result.conflicts, []);
});
test('same-setting conflicts retain both choices and can be resolved explicitly', () => {
	const base = defaults(), local = defaults(), remote = defaults();
	local.theme = 'night'; remote.theme = 'hacker';
	const result = mergeSettings(base, local, remote);
	assert.equal(result.conflicts[0].path, '/theme');
	assert.equal(mergeSettings(base, local, remote, { '/theme': 'remote' }).settings.theme, 'hacker');
	assert.deepEqual(mergeSettings(base, local, local).conflicts, []);
});

test('older files migrate Lock Screen settings and reject invalid new settings', () => {
	const legacy: any = defaults(); delete legacy.widgets.lockScreen;
	legacy.widgets.display.timeStyle = 'clock';
	const migrated = validateSettings(legacy);
	assert.deepEqual(migrated.widgets.lockScreen.display.fields, ['carType', 'stationName']);
	assert.equal(migrated.widgets.lockScreen.display.timeStyle, 'clock');
	assert.equal(migrated.widgets.lockScreen.display.trainsPerDirection, 2);
	assert.throws(() => validateSettings({ ...migrated, widgets: { ...migrated.widgets, lockScreen: { ...migrated.widgets.lockScreen, showService: 'false' } } }));
});

test('native refresh intervals survive web file round trips', () => {
	const settings = defaults();
	const display: any = settings.widgets.display;
	const lock: any = settings.widgets.lockScreen.display;
	display.refreshInterval = 1; lock.refreshInterval = 30;
	const restored = decodeNerds(encodeNerds(settings, '602')).settings;
	assert.equal((restored.widgets.display as any).refreshInterval, 1);
	assert.equal((restored.widgets.lockScreen.display as any).refreshInterval, 30);
	display.refreshInterval = 3;
	assert.throws(() => validateSettings(settings));
});


test('shared v2 fixture preserves exact foot values and train identities across platforms', () => {
	const text = readFileSync(new URL('./fixtures/favorites.nerds', import.meta.url), 'utf8');
	assert.equal(text, readFileSync(new URL('../ios/TransitCore/Tests/TransitCoreTests/Fixtures/favorites.nerds', import.meta.url), 'utf8'));
	const file = decodeNerds(text);
	assert.equal(file.settings.stationSelection.radiusFeet, 1);
	assert.equal(file.settings.widgets.stationSelection.selection.radiusFeet, 26400);
	assert.equal(file.settings.trainFavorites.match, 'anyCar');
	assert.deepEqual(file.settings.trainFavorites.cars, ['nyct:R211A:4149', 'sir:R211S:100']);
	assert.deepEqual(decodeNerds(encodeNerds(file.settings, file.lastStation)).settings, file.settings);
});
