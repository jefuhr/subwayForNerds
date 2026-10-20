import test from 'node:test';
import assert from 'node:assert/strict';
import { combinedPosition } from '../src/departure-row-display';

test('combined positions preserve historical prefixes and omit missing parts cleanly', () => {
	assert.equal(combinedPosition('At Newkirk Plaza', '1 stop away', '25s ago', false), 'At Newkirk Plaza · 1 stop away · 25s ago');
	assert.equal(combinedPosition('At Newkirk Plaza', '2 stops away', '2m ago', true), 'Last report: At Newkirk Plaza · 2 stops away · 2m ago');
	assert.equal(combinedPosition('', '2 stops away', '2m ago', true), '2 stops away · 2m ago');
	assert.equal(combinedPosition(undefined, '', '25s ago', false), 'Stop-relative position · 25s ago');
	assert.equal(combinedPosition('At Newkirk Plaza', '', '25s ago', false), 'At Newkirk Plaza · 25s ago');
	assert.equal(combinedPosition('At Newkirk Plaza', '', '', false), 'At Newkirk Plaza');
	assert.equal(combinedPosition(undefined, '', '', false), 'Stop-relative position');
});
