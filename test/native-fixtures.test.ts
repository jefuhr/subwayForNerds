import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { nativeFixtures } from '../scripts/export-native-fixtures';
import type { Board, Train, TransferResult } from '../shared/types';
import type { FleetOfflineManifest } from '../shared/offline';

test('native contract fixtures reproduce real API responses with deterministic recorded data', async () => {
  const generated = await nativeFixtures();
  assert.equal(Object.keys(generated).length, 10);
  for (const [name, data] of Object.entries(generated)) {
    const bytes = await readFile(new URL(`fixtures/native/${name}`, import.meta.url));
    const swiftBytes = await readFile(new URL(`../ios/TransitCore/Tests/TransitCoreTests/Fixtures/${name}`, import.meta.url));
    assert.deepEqual(swiftBytes, bytes, `${name}: Swift resources differ; run npm run fixtures:native`);
    const recorded = JSON.parse(bytes.toString('utf8'));
    if (name === 'offline-manifest.json') {
      // SQLite header/version and page layout may differ between supported Node
      // runtimes. Validate its real artifact identity while comparing wire data.
      const manifest = data as FleetOfflineManifest;
      const stable = ({ id: _id, sha256: _sha, byteLength: _size, downloadURL: _url, compressedByteLength: _compressedSize, compressedSha256: _compressedHash, ...metadata }: FleetOfflineManifest) => metadata;
      assert.deepEqual(stable(manifest), stable(recorded));
      assert.match(manifest.id, /^[a-f0-9]{64}$/);
      assert.equal(manifest.id, manifest.sha256);
      assert.ok(manifest.byteLength > 0);
      assert.ok(manifest.downloadURL.endsWith(`/snapshots/${manifest.id}.sqlite.gz`));
    } else assert.deepEqual(data, recorded, `${name} diverged; regenerate native fixtures and copy the Swift test resources`);
  }
  const trip = (generated['edge-trip.json'] as { train: Train }).train;
  assert.equal(trip.assigned, false);
  assert.equal(trip.position!.timestamp, 0);
  assert.equal(trip.stops[0].arrival, 0);
  assert.equal(trip.stops[0].departure, null);
  assert.equal(trip.stops[0].sequence, 0);
  assert.deepEqual(trip.stops.filter(stop => stop.id === '635N').map(stop => stop.sequence), [0, 1, 3]);
  assert.ok(trip.key.includes('/?=#'));
  assert.ok((generated['edge-board.json'] as Board).departures.some(departure => !('assigned' in departure)));
  assert.ok((generated['transfers.json'] as TransferResult).connections.length > 0);
});
