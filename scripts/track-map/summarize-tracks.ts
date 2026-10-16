import { readFileSync,writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
const snapshots=[];
for(const feed of ['gtfs','gtfs-ace','gtfs-bdfm','gtfs-g','gtfs-jz','gtfs-l','gtfs-nqrw']) {
	const data=JSON.parse(readFileSync(`artifacts/track-map/${feed}-tracks.json`,'utf8'));
	const observed=new Map<string,any>();
	for(const row of data.rows) {
		const item={route:row.route,stopId:row.stopId,actualTrack:row.actual_track??'',scheduledTrack:row.scheduled_track??''};
		if(item.actualTrack||item.scheduledTrack)observed.set(JSON.stringify(item),item);
	}
	snapshots.push({feed,url:`https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2F${feed}`,fetchedAt:data.fetchedAt,feedTimestamp:data.header.timestamp,sha256:createHash('sha256').update(readFileSync(`artifacts/track-map/${feed}.pb`)).digest('hex'),observations:[...observed.values()].sort((a,b)=>JSON.stringify(a).localeCompare(JSON.stringify(b)))});
}
writeFileSync('data/track-map/track-code-evidence.json',JSON.stringify({snapshots,note:'One bounded read-only request per subway feed. Observed codes are not permanent operating rules and do not independently identify PDF rails; manual source-path annotation supplies the physical correspondence. Train identifiers and stop times are intentionally omitted.'},null,'\t')+'\n');
console.log(`${snapshots.length} feed snapshots summarized`);
