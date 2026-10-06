import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { defaults, encodeNerds, decodeNerds, validateSettings, mergeSettings } from '../shared/settings';

test('nerds files round trip native-only preferences and unknown station references', () => {
	const file = decodeNerds(readFileSync(new URL('./fixtures/settings.nerds', import.meta.url), 'utf8'));
	assert.equal(file.settings.widgets.stations['future:station'].view, 'corridor');
	assert.deepEqual(decodeNerds(encodeNerds(file.settings, file.lastStation)).settings, file.settings);
});
test('invalid, oversized and unsupported imports fail before replacement', () => {
	for (const text of ['{}', 'null', '{', ' '.repeat(1048577), encodeNerds(defaults(), '602').replace('"version": 1', '"version": 2')]) assert.throws(() => decodeNerds(text));
	const value = defaults(); value.widgets.display.trainsPerDirection = 9;
	assert.throws(() => validateSettings(value));
	assert.throws(() => validateSettings({ ...defaults(), stations: JSON.parse('{"__proto__":{}}') }));
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
