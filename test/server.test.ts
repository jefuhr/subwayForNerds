import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer } from '../server/index';
import { TransitService } from '../server/service';
import { decode } from '../server/decode';

test('station APIs are indexed, conditional, isolated from upstream, and resilient to feed failure', async () => {
  let fetched = 0;
  const service = new TransitService({ fetcher: (async () => { fetched++; throw new Error('Must not fetch on request'); }) as typeof fetch });
  const raw = decode(readFileSync(new URL('fixtures/gtfs.pb', import.meta.url)));
  service.accept('gtfs', raw, Number(raw.header.timestamp));
  service.slots.get('gtfs-l')!.state.error = 'Simulated L feed outage'; service.refreshBoards();
  const app = await createServer(service);
  try {
    const response = await app.inject('/subwaysForNerds/api/v1/stations/602/board');
    assert.equal(response.statusCode, 200); assert.ok(response.json().departures.length);
    assert.ok(response.json().sources.some((s: any) => s.id === 'gtfs-l' && s.error));
    const unchanged = await app.inject({ url: '/subwaysForNerds/api/v1/stations/602/board', headers: { 'if-none-match': response.headers.etag! } });
    assert.equal(unchanged.statusCode, 304);
    const unknown = await app.inject('/subwaysForNerds/api/v1/stations/not-a-station/board'); assert.equal(unknown.statusCode, 404);
    const rootApi = await app.inject('/api/v1/stations'); assert.equal(rootApi.statusCode, 404);
    const trip = await app.inject('/subwaysForNerds/api/v1/trips?key=' + encodeURIComponent(response.json().departures[0].tripKey));
    assert.equal(trip.statusCode, 200); assert.ok(trip.json().raw.length);
    assert.equal(fetched, 0);
  } finally { await app.close(); }
});
test('older feeds cannot overwrite newer data, and missing trips are removed without invented cancellations', () => {
  const service = new TransitService();
  const raw = decode(readFileSync(new URL('fixtures/gtfs.pb', import.meta.url)));
  service.accept('gtfs', raw, raw.header.timestamp);
  assert.throws(() => service.accept('gtfs', { ...raw, header: { timestamp: raw.header.timestamp - 1 } }, raw.header.timestamp));
  const previous = service.slots.get('gtfs')!.trains.size; assert.ok(previous > 0);
  service.accept('gtfs', { header: { timestamp: raw.header.timestamp + 30 }, entity: [] }, raw.header.timestamp + 30);
  assert.equal(service.slots.get('gtfs')!.trains.size, 0);
});
