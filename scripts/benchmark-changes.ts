// Local-only diagnostic. Reads cached feed fixtures, downloads public schedules,
// and serves an ephemeral loopback API. No production writes or fleet mutations.
import { readFileSync } from 'node:fs';
import { Worker } from 'node:worker_threads';
import { TransitService } from '../server/service';
import { createServer } from '../server/index';
import type { Schedules } from '../server/schedules';

const service = new TransitService();
let capture = 0;
for (const id of service.slots.keys()) {
  const data = JSON.parse(readFileSync(`state/${id}.json`, 'utf8'));
  capture = Math.max(capture, Number(data.raw.header.timestamp));
  service.accept(id, data.raw, data.fetchedAt);
}
function schedule() {
  return new Promise<Schedules>((resolve,reject) => {
    const worker = new Worker(new URL('../server/schedule-worker.mjs',import.meta.url), { execArgv:[] });
    worker.once('message',data=>data.error ? reject(Error(data.error)) : resolve(data));
    worker.once('error',reject);
  });
}
const start = performance.now();
service.schedules = await schedule();
// Preserve the captured service day while exercising newly parsed schedules.
service.schedules.timestamp = capture;
const cold = performance.now(); service.refreshBoards(capture);
console.log(JSON.stringify({scheduleSeconds:(cold-start)/1000,initialRefreshMs:performance.now()-cold,trainCount:service.details.size,
  changes:[...service.details.values()].reduce((n,d)=>n+(d.train.changes?.length||0),0)}));
const app = await createServer(service);
await app.listen({port:0,host:'127.0.0.1'});
const address = app.server.address();
if (!address || typeof address === 'string') throw Error('Missing local listener');
const url = `http://127.0.0.1:${address.port}/subwaysForNerds/api/v1/stations/602/board`;
await fetch(url).then(r=>r.arrayBuffer());
async function sample(count: number) {
  const latencies: number[] = []; let next=0;
  await Promise.all(Array.from({length:50},async()=>{
    while(next++<count) { const t=performance.now(); const response=await fetch(url); if(!response.ok) throw Error(`HTTP ${response.status}`); await response.arrayBuffer(); latencies.push(performance.now()-t); }
  }));
  return latencies;
}
function summarize(latencies: number[]) {
  latencies.sort((a,b)=>a-b);
  return {requests:latencies.length,p95Ms:latencies[Math.floor(latencies.length*.95)],maxMs:latencies.at(-1)};
}
let timer: ReturnType<typeof setInterval> | undefined;
try {
  const idle = summarize(await sample(1000));
  const refreshTimes: number[] = [];
  timer = setInterval(()=>{const t=performance.now();service.refreshBoards(capture);refreshTimes.push(performance.now()-t);},1000);
  let finished=false, importError: unknown;
  const importing = schedule().then(result=>{
    service.schedules=result; result.timestamp=capture;
    const t=performance.now(); service.refreshBoards(capture); refreshTimes.push(performance.now()-t);
  }).catch(error=>{importError=error;}).finally(()=>{finished=true;});
  const measurements: number[]=[];
  while(!finished) measurements.push(...await sample(500));
  await importing;
  if(importError) throw importError;
  clearInterval(timer);
  console.log(JSON.stringify({idle,loaded:summarize(measurements),refreshMaxMs:Math.max(...refreshTimes),rssMB:process.memoryUsage().rss/1024/1024}));
} finally { clearInterval(timer); await app.close(); }
