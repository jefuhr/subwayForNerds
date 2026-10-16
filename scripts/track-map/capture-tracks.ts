// Explicit, bounded read-only snapshot. Never used in production or run by the build.
import { mkdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { decode, extension } from '../../server/decode';
const feeds=process.argv.slice(2);
const allowed=new Set(['gtfs','gtfs-ace','gtfs-bdfm','gtfs-g','gtfs-jz','gtfs-l','gtfs-nqrw']);
if(!feeds.length||feeds.length>7||feeds.some(feed=>!allowed.has(feed)))throw Error('pass 1–7 subway feeds; SIR and regional feeds are excluded');
await mkdir('artifacts/track-map',{recursive:true});
for(const feed of [...new Set(feeds)]) {
	const url=`https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2F${feed}`;
	const response=await fetch(url,{signal:AbortSignal.timeout(15000)});
	if(!response.ok)throw Error(`${feed}: HTTP ${response.status}`);
	const bytes=new Uint8Array(await response.arrayBuffer()),decoded=decode(bytes);
	const rows=decoded.entity.flatMap((entity:any)=>(entity.trip_update?.stop_time_update??[]).map((stop:any)=>({route:entity.trip_update.trip.route_id,stopId:stop.stop_id,...extension(stop,'nyct_stop_time_update')})));
	await writeFile(`artifacts/track-map/${feed}.pb`,bytes);
	await writeFile(`artifacts/track-map/${feed}-tracks.json`,JSON.stringify({url,fetchedAt:new Date().toISOString(),sha256:createHash('sha256').update(bytes).digest('hex'),header:decoded.header,rows},null,'\t')+'\n');
	console.log(`${feed}: ${rows.length} stop observations, timestamp ${decoded.header.timestamp}`);
}
