import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { defaults, defaultOffline, effectiveTripDetailsPerLineDirection, encodeNerds, decodeNerds, validateSettings, mergeSettings } from '../shared/settings';

test('nerds files round trip native-only preferences and unknown station references', () => {
	const file = decodeNerds(readFileSync(new URL('./fixtures/settings.nerds', import.meta.url), 'utf8'));
	assert.equal(file.settings.widgets.stations['future:station'].view, 'corridor');
	assert.equal(file.settings.widgets.lockScreen.directionOrder, 'uptownLeft');
	assert.deepEqual(decodeNerds(encodeNerds(file.settings, file.lastStation)).settings, file.settings);
});
test('invalid, oversized and unsupported imports fail before replacement', () => {
	for (const text of ['{}', 'null', '{', ' '.repeat(1048577), encodeNerds(defaults(), '602').replace('"version": 4', '"version": 5')]) assert.throws(() => decodeNerds(text));
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
	assert.equal(file.version, 4);
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

test('v3 exports offline preferences and v1/v2 files migrate to offline defaults', () => {
	assert.deepEqual(defaults().offline, { departuresPerLineDirection: 5, tripDetailsPerLineDirection: 2, saveOpenedTrips: true, nearbyRadiusFeet: 2640, preloadOtherStationTrips: false, estimateLimitMinutes: 30, retentionHours: 6, storageLimitMiB: 50, widgetsFollowActiveRide: false });
	for (const name of ['settings.nerds', 'favorites.nerds']) {
		const legacy = decodeNerds(readFileSync(new URL('./fixtures/' + name, import.meta.url), 'utf8'));
		assert.ok(legacy.version < 3);
		assert.deepEqual(legacy.settings.offline, defaultOffline());
	}
	const settings = defaults();
	settings.offline = { ...settings.offline, departuresPerLineDirection: 20, nearbyRadiusFeet: 0, estimateLimitMinutes: 120, widgetsFollowActiveRide: true };
	const exported = JSON.parse(encodeNerds(settings, '602'));
	assert.equal(exported.version, 4);
	assert.deepEqual(exported.settings.offline, settings.offline);
	assert.deepEqual(decodeNerds(JSON.stringify(exported)).settings.offline, settings.offline);
	// Settings without offline (older sync baselines and clients) migrate in place.
	const legacy: any = defaults(); delete legacy.offline;
	assert.deepEqual(validateSettings(legacy).offline, defaultOffline());
});

test('offline preferences validate every field strictly at its boundaries', () => {
	const accepted: Record<string, unknown[]> = {
		departuresPerLineDirection: [1, 20], tripDetailsPerLineDirection: [0, 20], saveOpenedTrips: [true, false], nearbyRadiusFeet: [0, 26400],
		preloadOtherStationTrips: [true, false], estimateLimitMinutes: [5, 15, 30, 60, 120], retentionHours: [1, 6, 12, 24], storageLimitMiB: [25, 50, 100, 250], widgetsFollowActiveRide: [true, false],
	};
	const rejected: Record<string, unknown[]> = {
		departuresPerLineDirection: [0, 21, 1.5, '5', null], tripDetailsPerLineDirection: [-1, 21, 0.5, false], saveOpenedTrips: [1, 'true', null], nearbyRadiusFeet: [-1, 26401, 2640.5, '2640'],
		preloadOtherStationTrips: [0, 'false'], estimateLimitMinutes: [0, 10, 31, 30.5, '30'], retentionHours: [0, 2, 48, '6'], storageLimitMiB: [0, 10, 500, '50'], widgetsFollowActiveRide: ['yes', null],
	};
	for (const [key, values] of Object.entries(accepted)) for (const value of values) {
		assert.equal((validateSettings({ ...defaults(), offline: { ...defaultOffline(), [key]: value } }).offline as any)[key], value, key + '=' + value);
	}
	for (const [key, values] of Object.entries(rejected)) for (const value of values) {
		assert.throws(() => validateSettings({ ...defaults(), offline: { ...defaultOffline(), [key]: value } }), Error, key + '=' + String(value));
	}
	const missing: any = defaultOffline(); delete missing.retentionHours;
	for (const offline of [missing, { ...defaultOffline(), extra: 1 }, null, [], 'default']) assert.throws(() => validateSettings({ ...defaults(), offline }));
	// Trip details validate independently; the effective count is clamped where it is used.
	const independent = validateSettings({ ...defaults(), offline: { ...defaultOffline(), departuresPerLineDirection: 1, tripDetailsPerLineDirection: 20 } }).offline;
	assert.equal(effectiveTripDetailsPerLineDirection(independent), 1);
	assert.equal(effectiveTripDetailsPerLineDirection(defaultOffline()), 2);
});

test('offline preferences are required in v3 files and never part of older versions', () => {
	const v3 = JSON.parse(encodeNerds(defaults(), '602'));
	delete v3.settings.offline;
	assert.throws(() => decodeNerds(JSON.stringify(v3)));
	for (const version of [1, 2]) {
		const older = JSON.parse(encodeNerds(defaults(), '602'));
		older.version = version;
		assert.throws(() => decodeNerds(JSON.stringify(older)));
		delete older.settings.offline; delete older.settings.combinedStations; delete older.settings.hiddenRoutes;
		assert.deepEqual(decodeNerds(JSON.stringify(older)).settings.offline, defaultOffline());
	}
	const invalid = JSON.parse(encodeNerds(defaults(), '602'));
	invalid.settings.offline.storageLimitMiB = 75;
	assert.throws(() => decodeNerds(JSON.stringify(invalid)));
});

test('offline preferences merge field by field and conflict explicitly', () => {
	const base = defaults(), local = structuredClone(base), remote = structuredClone(base);
	local.offline.retentionHours = 24; remote.offline.storageLimitMiB = 250;
	local.offline.estimateLimitMinutes = 5; remote.offline.estimateLimitMinutes = 120;
	const result = mergeSettings(base, local, remote);
	assert.equal(result.settings.offline.retentionHours, 24);
	assert.equal(result.settings.offline.storageLimitMiB, 250);
	assert.deepEqual(result.conflicts.map(c => c.path), ['/offline/estimateLimitMinutes']);
	assert.equal(mergeSettings(base, local, remote, { '/offline/estimateLimitMinutes': 'remote' }).settings.offline.estimateLimitMinutes, 120);
	const legacyBase: any = defaults(); delete legacyBase.offline;
	assert.equal(mergeSettings(legacyBase, local, base).settings.offline.retentionHours, 24);
});

test('shared v3 offline fixture is identical across platforms and round trips', () => {
	const text = readFileSync(new URL('./fixtures/offline.nerds', import.meta.url), 'utf8');
	assert.equal(text, readFileSync(new URL('../ios/TransitCore/Tests/TransitCoreTests/Fixtures/offline.nerds', import.meta.url), 'utf8'));
	const file = decodeNerds(text);
	assert.equal(file.version, 3);
	assert.deepEqual(file.settings.offline, { departuresPerLineDirection: 20, tripDetailsPerLineDirection: 0, saveOpenedTrips: false, nearbyRadiusFeet: 0, preloadOtherStationTrips: true, estimateLimitMinutes: 120, retentionHours: 24, storageLimitMiB: 250, widgetsFollowActiveRide: true });
	assert.deepEqual(decodeNerds(encodeNerds(file.settings, file.lastStation)).settings, file.settings);
});
