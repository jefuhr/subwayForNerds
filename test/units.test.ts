import test from 'node:test';
import assert from 'node:assert/strict';
import { clockTime, clockDateTime, sourceClockText, countdown, distanceLabel, radiusDisplayValue, radiusFeetFromInput } from '../shared/display';
import { decodeNerds, defaults, encodeNerds, mergeSettings, validateSettings, type UnitSettings } from '../shared/settings';

test('missing units migrate in stored settings and both supported file versions', () => {
	const settings: any = defaults(); delete settings.units;
	assert.deepEqual(validateSettings(settings).units, { distance: 'auto', time: '12h' });
	for (const version of [1, 2]) {
		const file = { format: 'subways-for-nerds', version, exportedAt: '2026-10-10T12:00:00Z', lastStation: '602', settings };
		assert.deepEqual(decodeNerds(JSON.stringify(file)).settings.units, { distance: 'auto', time: '12h' });
	}
});

test('unit settings are strict, portable, and merge independently', () => {
	for (const units of [null, {}, { distance: 'km' }, { distance: 'km', time: '24h', extra: true }, { distance: 'miles', time: '12h' }, { distance: 'ft', time: '24' }]) {
		assert.throws(() => validateSettings({ ...defaults(), units }));
	}
	for (const distance of ['auto', 'mi', 'ft', 'm', 'km'] as const) {
		const settings = defaults(); settings.units = { distance, time: '24h' };
		const file = decodeNerds(encodeNerds(settings, '602'));
		assert.equal(file.version, 2); assert.deepEqual(file.settings.units, settings.units);
	}
	const base = defaults(), local = defaults(), remote = defaults();
	local.units.distance = 'mi'; remote.units.time = '24h';
	assert.deepEqual(mergeSettings(base, local, remote).settings.units, { distance: 'mi', time: '24h' });
	remote.units.distance = 'km';
	assert.deepEqual(mergeSettings(base, local, remote).conflicts.map(c => c.path), ['/units/distance']);
	assert.equal(mergeSettings(base, local, remote, { '/units/distance': 'remote' }).settings.units.distance, 'km');
});

test('wall clocks keep Eastern time and use 00 at midnight while countdowns remain minutes', () => {
	const midnight = Date.parse('2026-10-10T04:00:00Z') / 1000;
	assert.equal(clockTime(midnight, '12h'), '12:00 AM');
	assert.equal(clockTime(midnight, '24h'), '00:00');
	assert.equal(clockTime(midnight + 13 * 3600 + 300, '24h'), '13:05');
	assert.match(clockDateTime(midnight, '24h'), /10\/10\/2026.*00:00/);
	assert.equal(clockTime(Date.parse('2026-01-10T05:00:00Z') / 1000, '24h'), '00:00');
	assert.deepEqual(countdown(midnight + 120, midnight, midnight, false, '24h'), { value: '2', unit: 'min' });
	assert.deepEqual(countdown(midnight + 120, midnight, midnight, true, '24h'), { value: '00:02', unit: 'last estimate' });
	assert.deepEqual(countdown(midnight + 120, midnight - 91, midnight, false, '24h'), { value: '00:02', unit: 'last estimate' });
	assert.equal(clockTime(null, '24h'), '—');
});

test('nearby distance units preserve auto behavior and convert explicit units', () => {
	assert.equal(distanceLabel(500, 'auto'), '500 m');
	assert.equal(distanceLabel(1609.344, 'auto'), '1.6 km');
	assert.equal(distanceLabel(1609.344, 'mi'), '1 mi');
	assert.equal(distanceLabel(1609.344, 'ft'), '5,280 ft');
	assert.equal(distanceLabel(1609.344, 'm'), '1,609 m');
	assert.equal(distanceLabel(1609.344, 'km'), '1.61 km');
	assert.equal(distanceLabel(1, 'mi'), '<0.01 mi');
});

test('published outage clock strings keep their date and never guess a timezone for unrecognized text', () => {
	assert.equal(sourceClockText('09/05/2026 08:00 PM', '24h'), '09/05/2026 20:00');
	assert.equal(sourceClockText('09/06/2026 12:00 AM', '24h'), '09/06/2026 00:00');
	assert.equal(sourceClockText('09/06/2026 12:00 PM', '24h'), '09/06/2026 12:00');
	assert.equal(sourceClockText('09/05/2026 20:00', '12h'), '09/05/2026 8:00 PM');
	assert.equal(sourceClockText('09/05/2026 08:00 PM', '12h'), '09/05/2026 08:00 PM');
	for (const text of ['Return time unknown', '9/5/2026', '09/05/2026 99:00 AM', '2026-09-05T20:00:00']) assert.equal(sourceClockText(text, '24h'), text);
});

test('radius editing round trips every unit without changing integer-foot station boundaries', () => {
	const units: UnitSettings['distance'][] = ['auto', 'mi', 'ft', 'm', 'km'];
	for (const unit of units) for (let feet = 1; feet <= 26400; feet++) {
		assert.equal(radiusFeetFromInput(radiusDisplayValue(feet, unit), unit), feet, `${feet} ft in ${unit}`);
	}
	assert.equal(radiusFeetFromInput('1', 'mi'), 5280);
	assert.equal(radiusFeetFromInput('1609.344', 'm'), 5280);
	assert.equal(radiusFeetFromInput('1.609344', 'km'), 5280);
	assert.equal(radiusFeetFromInput('0.5', 'm'), 2);
	for (const value of ['', ' ', '-1', '0', 'garbage', 'Infinity', '1e2']) assert.equal(radiusFeetFromInput(value, 'ft'), null);
	assert.equal(radiusFeetFromInput('5.1', 'mi'), null);
	for (const feet of [0.5, 0.6, 26400.4, 26400.5]) {
		for (const unit of units) assert.equal(radiusFeetFromInput(radiusDisplayValue(feet, unit), unit), null, `${feet} ft in ${unit} is outside the allowed range`);
	}
});
