import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer } from '../server/index';
import { TransitService } from '../server/service';
import { decode } from '../server/decode';
import { changeStale } from '../shared/changes';

test('change summaries reach boards and transfers while explanations stay in trip details', async () => {
  const now=Math.floor(Date.now()/1000), service=new TransitService();
  service.accept('gtfs',{header:{timestamp:now},entity:[{id:'changed',trip_update:{trip:{trip_id:'003000_4..N',route_id:'4',start_date:'20260908'},stop_time_update:[
    {stop_id:'635N',departure:{time:now+60},'.transit_realtime.nyct_stop_time_update':{scheduled_track:'3',actual_track:'4'}},
    {stop_id:'631N',arrival:{time:now+400}}
  ]}},{id:'connection',trip_update:{trip:{trip_id:'004000_4..N',route_id:'4',start_date:'20260908'},stop_time_update:[
    {stop_id:'631N',departure:{time:now+500},'.transit_realtime.nyct_stop_time_update':{scheduled_track:'3',actual_track:'4'}}
  ]}}]},now);
  const app=await createServer(service);
  try {
    const board=(await app.inject('/subwaysForNerds/api/v1/stations/602/board')).json();
    const d=board.departures[0]; assert.equal(d.changes[0].kind,'track'); assert.equal(d.changes[0].description,undefined);
    const detail=(await app.inject('/subwaysForNerds/api/v1/trips?key='+encodeURIComponent(d.tripKey))).json();
    assert.match(detail.train.changes[0].description,/reported track 4/);
    const transfers=(await app.inject('/subwaysForNerds/api/v1/trips/transfers?key='+encodeURIComponent(d.tripKey)+'&stopId=631N')).json();
    assert.equal(transfers.connections.length,1); assert.equal(transfers.connections[0].changes[0].kind,'track');
    service.slots.get('gtfs')!.state.error='Network failure'; service.refreshBoards(now);
    const stale=(await app.inject('/subwaysForNerds/api/v1/stations/602/board')).json();
    assert.equal(changeStale(stale.departures[0].changes[0],now),true);
  } finally {await app.close();}
});

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
