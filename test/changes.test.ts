import test from 'node:test';
import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ChangeDetector, patternDifference } from '../server/changes';
import { daytimePatterns, matchedTrip, serviceActive, serviceTime, type Schedules } from '../server/schedules';
import { changesAhead, changeStale } from '../shared/changes';
import { normalizeAlerts } from '../server/transit';
import type { ServiceAlert, SourceState, Train } from '../shared/types';

const now = Date.parse('2026-09-08T04:30:00Z') / 1000;
const state: SourceState = { id: 'subway-alerts', timestamp: now, fetchedAt: now, error: null };
const train = (stops = ['635N','634N','633N','632N','631N']): Train => ({ key:'gtfs|20260908|003000_4..N|', tripId:'003000_4..N', serviceDate:'20260908', route:'4', feed:'gtfs', direction:'NORTH', timestamp:now, destination:'Terminal', alerts:[], stops:stops.map((id,i)=>({ id, name:id, arrival:now+i*120+60, departure:null })) });
const alert = (patch: Partial<ServiceAlert> = {}): ServiceAlert => ({ id:'a', title:'Planned local service', description:'Work', routes:['4'], stops:[], selectors:[{ route:'4', direction:0 }], periods:[], alertType:'Planned - Express to Local', ...patch });
const calendar = [{ service_id:'daily', monday:'1', tuesday:'1', wednesday:'1', thursday:'1', friday:'1', saturday:'1', sunday:'1', start_date:'20260101', end_date:'20261231' }];
function schedules(): Schedules {
  return { version:2, timestamp:now, feeds:[{ name:'gtfs_subway', stops:[], calendar, exceptions:[], patterns:[
    { route:'4', shape:'4..N', headsign:'Terminal', direction:0, stops:['635N','634N','633N','632N','631N'], source:'gtfs_subway' },
    { route:'4', shape:'4..Nexpress', headsign:'Terminal', direction:0, stops:['635N','631N'], source:'gtfs_subway' }
  ], trips:[{ id:'PREFIX_003000_4..N', service:'daily', pattern:0, start:1800, times:[1800,1920,2040,2160,2280] },
    { id:'PREFIX_072000_4..Nexpress', service:'daily', pattern:1, start:43200, times:[43200,43600] }] }] };
}
test('weekday daytime reference distinguishes routine overnight local stops', () => {
  const t=train(); new ChangeDetector().enrich(t,[],state,schedules(),now);
  const c=t.changes!.find(c=>c.id==='scheduled-pattern')!;
  assert.equal(c.classification,'scheduled'); assert.match(c.label,/overnight/); assert.match(c.description!,/weekday daytime/);
  assert.equal(changesAhead(t.changes,4).length,0, 'change is behind the last stop');
  assert.ok(t.stops[1].changes?.length);
});
test('weekend differs from weekday baseline but is not an unplanned disruption', () => {
  const t=train(); t.serviceDate='20260906';
  const time=Date.parse('2026-09-06T16:00:00Z')/1000;
  t.timestamp=time; t.stops.forEach((s,i)=>{s.arrival=time+60+i*120;});
  const s=schedules(); s.timestamp=time;
  new ChangeDetector().enrich(t,[],{...state,timestamp:time},s,time);
  assert.match(t.changes![0].label,/weekend/); assert.equal(t.changes![0].classification,'scheduled');
});
test('supplemented and live patterns distinguish planned and unexplained changes', () => {
  const s=schedules(); s.feeds[0].trips![0].pattern=1;
  const supplemented=structuredClone(s.feeds[0]); supplemented.name='gtfs_supplemented'; supplemented.trips![0].pattern=0; s.feeds.push(supplemented);
  const t=train(); new ChangeDetector().enrich(t,[],state,s,now);
  assert.equal(t.changes!.find(c=>c.id==='planned-pattern')?.classification,'planned');
  s.feeds.pop(); new ChangeDetector().enrich(t,[],state,s,now);
  assert.equal(t.changes!.find(c=>c.id==='live-pattern')?.classification,'unknown');
});
test('tracks distinguish mismatches, actual reassignment, and changing scheduled track', () => {
  const detector=new ChangeDetector(), t=train();
  t.stops[0].scheduledTrack='3'; t.stops[0].actualTrack='4';
  detector.enrich(t,[],state,undefined,now);
  assert.equal(t.changes![0].label,'track 4 · scheduled 3');
  t.stops[0].scheduledTrack='4'; t.timestamp+=15;
  detector.enrich(t,[],state,undefined,now+15);
  assert.equal(t.changes![0].label,'track 4 · was 3'); assert.match(t.changes![0].description!,/scheduled/);
  const other=train(); other.key+='other'; other.stops[0].scheduledTrack='4';
  detector.enrich(other,[],state,undefined,now); assert.equal(other.changes!.length,0);
});
test('a track change ahead cannot be mistaken for the boarding station track', () => {
  const t=train(); t.stops[2].actualTrack='4'; t.stops[2].scheduledTrack='3'; t.stops[2].name='23 St';
  new ChangeDetector().enrich(t,[],state,undefined,now);
  assert.match(changesAhead(t.changes,0)[0].label,/ahead at 23 St/);
  assert.doesNotMatch(changesAhead(t.changes,2)[0].label,/ahead/);
  assert.deepEqual(changesAhead(t.changes,3),[]);
});
test('explicit cancellations and skipped stops are retained without inferring a cause', () => {
  const t=train(); t.relationship='CANCELED'; t.stops[1].relationship='SKIPPED';
  new ChangeDetector().enrich(t,[],state,undefined,now);
  assert.ok(t.changes!.some(c=>c.kind==='cancellation'));
  assert.ok(t.changes!.some(c=>c.kind==='skip'));
  assert.ok(t.changes!.every(c=>c.classification==='unknown'));
});
test('cached analysis expires at passage boundaries and stale schedules do not invent changes', () => {
  const t=train(); t.stops[0].actualTrack='4'; t.stops[0].scheduledTrack='3';
  const detector=new ChangeDetector(), alerts: ServiceAlert[]=[];
  detector.enrich(t,alerts,state,undefined,now);
  const original=t.changes;
  detector.enrich(t,alerts,state,undefined,now+10); assert.equal(t.changes,original);
  detector.enrich(t,alerts,state,undefined,now+91); assert.equal(t.changes!.length,0);
  const s=schedules(); s.timestamp=now-7201;
  const other=train(); detector.enrich(other,[],state,s,now); assert.equal(other.changes!.length,0);
});
test('alerts match predicted passage, direction, trip service date, and exclusive end time', () => {
  const t=train(); const a=alert({ selectors:[{ route:'4',direction:0,stop:'634' }],periods:[{start:now+150,end:now+181}] });
  const d=new ChangeDetector(); d.enrich(t,[a],state,undefined,now);
  assert.equal(t.changes!.length,1); assert.deepEqual(t.changes![0].stopIndices,[1]); assert.equal(t.changes![0].advisory,true);
  a.periods[0].end=now+180; d.enrich(t,[a],state,undefined,now); assert.equal(t.changes!.length,0);
  a.periods=[]; a.selectors[0].direction=1; d.enrich(t,[a],state,undefined,now); assert.equal(t.changes!.length,0);
  a.selectors=[{trip:t.tripId,serviceDate:'20260907'}]; d.enrich(t,[a],state,undefined,now); assert.equal(t.changes!.length,0);
});
test('alerts for omitted stations use bounded estimated passage, never affect boards behind the change', () => {
  const t=train(['635N','631N']); t.stops[1].arrival=now+600;
  new ChangeDetector().enrich(t,[alert({selectors:[{route:'4',stop:'633'}],periods:[{start:now+300,end:now+400}]})],state,schedules(),now);
  const c=t.changes!.find(c=>c.id==='alert:a')!;
  assert.ok(c); assert.deepEqual(c.stopIndices,[0]); assert.equal(changesAhead([c],1).length,0);
});
test('ambiguous branches, prediction truncation and missing schedules do not invent changes', () => {
  assert.equal(patternDifference(['a','b','c','d'],['b','c']),undefined);
  assert.equal(patternDifference(['a','b','c'],['c','b']),undefined);
  const t=train(['634N','633N']); new ChangeDetector().enrich(t,[],state,undefined,now); assert.deepEqual(t.changes,[]);
  const s=schedules(); s.feeds[0].patterns.push({...s.feeds[0].patterns[1],stops:['635N','634N','631N']});
  s.feeds[0].trips!.push({...s.feeds[0].trips![1],id:'OTHER',pattern:2});
  new ChangeDetector().enrich(train(),[],state,s,now);
  const normal=train(); new ChangeDetector().enrich(normal,[],state,s,now); assert.equal(normal.changes!.length,0);
});
test('unplanned classification requires source evidence and freshness stays independent', () => {
  const t=train(); new ChangeDetector().enrich(t,[alert({alertType:'Stops Skipped',title:'Stops skipped',description:'Signal problem'})],{...state,error:'Unavailable'},undefined,now);
  assert.equal(t.changes![0].classification,'unplanned'); assert.ok(changeStale(t.changes![0],now));
  new ChangeDetector().enrich(t,[alert({alertType:'Stops Skipped',title:'Unplanned service change',description:'Signal problem'})],state,undefined,now);
  assert.equal(t.changes![0].classification,'unplanned');
  new ChangeDetector().enrich(t,[alert({alertType:'Delays',title:'Delays during planned track maintenance'})],state,undefined,now);
  assert.equal(t.changes![0].classification,'planned'); assert.ok(changeStale(t.changes![0],now,true));
});
test('calendars honor holiday overrides and GTFS service time handles midnight and DST', () => {
  const f=schedules().feeds[0]; f.exceptions=[{service_id:'daily',date:'20260908',exception_type:'2'}];
  assert.equal(serviceActive(f,'daily','20260908'),false); assert.equal(matchedTrip(f,train()),undefined);
  assert.equal(serviceTime('20260908',25*3600),Date.parse('2026-09-09T05:00:00Z')/1000);
  assert.equal(serviceTime('20260308',43200),Date.parse('2026-03-08T16:00:00Z')/1000);
  assert.equal(serviceTime('20261101',43200),Date.parse('2026-11-01T17:00:00Z')/1000);
  assert.equal(serviceTime('20260308',0),Date.parse('2026-03-08T04:00:00Z')/1000);
});
test('trip matching rejects ambiguous origin identities and daytime keeps direction variants', () => {
  const f=schedules().feeds[0], t=train(); assert.ok(matchedTrip(f,t));
  t.tripId='003000_unknown'; assert.ok(matchedTrip(f,t));
  f.trips!.push({...f.trips![0],id:'OTHER_003000_other',pattern:1});
  // New immutable feed builds a new index, as schedule refresh does.
  assert.equal(matchedTrip(structuredClone(f),t),undefined);
  assert.equal(daytimePatterns(f,train()).length,1);
});
test('normalization preserves Mercury classification and selector constraints', () => {
  const [a]=normalizeAlerts({entity:[{id:'a',alert:{informed_entity:[{route_id:'4',direction_id:0,trip:{trip_id:'trip',start_date:'20260908'},'.transit_realtime.mercury_entity_selector':{sort_order:'MTASBWY:4:16'}}],'.transit_realtime.mercury_alert':{alert_type:'Planned - Stops Skipped',affected_stations:[{route_id:'4',stop_id:'634',direction_id:1}],human_readable_active_period:{translation:[{text:'Overnight',language:'en'}]}}}}]});
  assert.equal(a.alertType,'Planned - Stops Skipped'); assert.equal(a.selectors[0].direction,0); assert.equal(a.selectors[0].priority,16);
  assert.equal(a.selectors[0].serviceDate,'20260908'); assert.equal(a.affectedSelectors![0].direction,1); assert.equal(a.activePeriodLabel,'Overnight');
});
test('schedule worker restores versioned caches and rejects old or corrupt schemas', async () => {
  const dir=await mkdtemp(join(tmpdir(),'sfn-change-cache-'));
  const file=join(dir,'schedules.json');
  const restore=()=>new Promise<any>((resolve,reject)=>{
    const worker=new Worker(new URL('../server/schedule-worker.mjs',import.meta.url),{execArgv:[],workerData:{restore:file}});
    worker.once('message',resolve); worker.once('error',reject);
  });
  try {
    await writeFile(file,JSON.stringify({version:1,feeds:[]})); assert.match((await restore()).error,/rebuilding/);
    await writeFile(file,JSON.stringify({version:2,timestamp:now,feeds:[{},{}]})); assert.match((await restore()).error,/rebuilding/);
    const valid=schedules(); valid.feeds.push({...structuredClone(valid.feeds[0]),name:'gtfs_supplemented'});
    await writeFile(file,JSON.stringify(valid)); const result=await restore(); assert.equal(result.version,2); assert.equal(result.feeds.length,2);
  } finally {await rm(dir,{recursive:true,force:true});}
});
