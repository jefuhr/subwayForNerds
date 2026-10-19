import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { defaults, defaultDepartureRows, decodeNerds, encodeNerds, mergeSettings, settingsChanges, validateSettings } from '../shared/settings';

const expected = { showTrackProvenance: false, combinePosition: true, showConsist: true, showHeadway: true };
const fixture = () => readFileSync(new URL('./fixtures/departure-rows.nerds', import.meta.url));

test('departure rows default and migrate legacy device, account and v1-v5 files', () => {
	assert.deepEqual(defaults().departureRows, expected);
	assert.deepEqual(defaultDepartureRows(), expected);
	const legacy: any = defaults(); delete legacy.departureRows;
	assert.deepEqual(validateSettings(legacy).departureRows, expected);
	for (const name of ['settings', 'favorites', 'offline', 'combined-stations', 'transfers']) {
		const file = decodeNerds(readFileSync(new URL(`./fixtures/${name}.nerds`, import.meta.url), 'utf8'));
		assert.deepEqual(file.settings.departureRows, expected, name);
	}
});

test('canonical v6 fixture has exact bytes and round trips all row preferences', () => {
	assert.equal(createHash('sha256').update(fixture()).digest('hex'), '1b49da759ba05383fec7a90ba8b9dbdf893ebf558418deff148a7e38975c5e80');
	const file = decodeNerds(fixture().toString());
	assert.equal(file.version, 6);
	assert.deepEqual(file.settings.departureRows, { showTrackProvenance: true, combinePosition: false, showConsist: false, showHeadway: true });
	const exported = decodeNerds(encodeNerds(file.settings, file.lastStation));
	assert.equal(exported.version, 6);
	assert.deepEqual(exported.settings, file.settings);
});

test('departure rows require exactly four booleans when present', () => {
	for (const key of Object.keys(expected)) {
		const missing: any = { ...expected }; delete missing[key];
		for (const departureRows of [missing, ...[null, 0, 'false', undefined].map(value => ({ ...expected, [key]: value }))]) {
			assert.throws(() => validateSettings({ ...defaults(), departureRows }), /not a valid Subway Nerds settings file/);
		}
	}
	for (const departureRows of [null, [], 'default', { ...expected, extra: true }]) {
		assert.throws(() => validateSettings({ ...defaults(), departureRows }), /not a valid Subway Nerds settings file/);
	}
});

test('v6 requires departure rows and v1-v5 cannot contain them', () => {
	const file = JSON.parse(fixture().toString());
	delete file.settings.departureRows;
	assert.throws(() => decodeNerds(JSON.stringify(file)), /not a valid/);
	for (const [index, name] of ['settings', 'favorites', 'offline', 'combined-stations', 'transfers'].entries()) {
		const older = JSON.parse(readFileSync(new URL(`./fixtures/${name}.nerds`, import.meta.url), 'utf8'));
		older.settings.departureRows = expected;
		assert.throws(() => decodeNerds(JSON.stringify(older)), /not a valid/, `v${index + 1}`);
	}
});

test('departure row edits merge per key and migrate older sync baselines', () => {
	const base = defaults(), local = structuredClone(base), remote = structuredClone(base);
	local.departureRows.combinePosition = false;
	remote.departureRows.showConsist = false;
	remote.departureRows.showTrackProvenance = true;
	const merged = mergeSettings(base, local, remote);
	assert.deepEqual(merged.conflicts, []);
	assert.deepEqual(merged.settings.departureRows, { showTrackProvenance: true, combinePosition: false, showConsist: false, showHeadway: true });
	assert.deepEqual(settingsChanges(base, local).map(change => change.path), ['departureRows / combinePosition']);
	// Two edits to a valid boolean either agree or leave one side unchanged, so cannot conflict.
	remote.departureRows.combinePosition = false;
	assert.deepEqual(mergeSettings(base, local, remote).conflicts, []);
	const legacy: any = structuredClone(base); delete legacy.departureRows;
	assert.deepEqual(mergeSettings(legacy, local, remote).settings.departureRows, merged.settings.departureRows);
});
