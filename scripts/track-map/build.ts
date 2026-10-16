import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import type { TrackMapPoint, TrackMapTopology } from '../../shared/track-map';
import { flattenCommands, concatenatePaths, project, distance, validateTopology, platformCenter, sourcePathId, selectSubpath, trimPathEnd, trimPathStart, platformDirectionsFor, railFlatteningTolerance, type SourceReference } from './topology';
const read = (path:string) => JSON.parse(readFileSync(new URL(`../../${path}`,import.meta.url),'utf8'));
const annotations=read('data/track-map/annotations.json');
const observations=read('data/track-map/track-code-evidence.json').snapshots.flatMap((s:any)=>s.observations.map((o:any)=>({...o,feed:s.feed,feedTimestamp:s.feedTimestamp})));
const catalog=read('data/stations.json').filter((s:any)=>!s.routes.includes('SIR'));
const expected='b28f75397b2e7b6ba0b67db6ea2181800baa0254a48261252f3d55c4f2b17c71';
if(annotations.sourceSha256!==expected)throw Error('annotation source hash mismatch');
if(process.argv[2]) {
	const hash=createHash('sha256').update(readFileSync(process.argv[2])).digest('hex');
	if(hash!==expected)throw Error('PDF source hash mismatch');
}
const topology:TrackMapTopology={schemaVersion:1,mapVersion:'nyc-2.6.8-v1',pdfSha256:expected,page:{width:7344,height:11540.6},attribution:'New York City Track Map by vanshnookenraggen, version 2.6.8. Local development/analysis only; written consent required before artwork distribution.',sourceURL:'https://www.vanshnookenraggen.com/_index/docs/NYC_full_trackmap.pdf',stations:[],nodes:[],edges:[],platforms:[],coverage:{mappedStopIds:[],unresolvedStopIds:[],notes:[...annotations.notes]}};
const source=(ref:SourceReference,precision=annotations.flatteningTolerance) => {
	const path=annotations.sourcePaths[String(sourcePathId(ref))];if(!path)throw Error(`missing source path ${JSON.stringify(ref)}`);
	const commands=typeof ref==='number'?path.commands:selectSubpath(path.commands,ref.subpath);
	const points=flattenCommands(commands,precision);
	return (typeof ref==='number'?ref<0:ref.reverse)?points.reverse():points;
};
const stationPoints=new Map<string,TrackMapPoint>();
const selectedPlatforms=new Map<string,string>();
for(const annotation of annotations.stations) {
	for(const id of annotation.platformPaths) {
		const key=typeof id==='number'?String(Math.abs(id)):`${id.pathId}:${id.subpath}`;
		if(selectedPlatforms.has(key))throw Error(`source platform ${key} reused by ${annotation.partId} and ${selectedPlatforms.get(key)}`);
		selectedPlatforms.set(key,annotation.partId);
	}
	const row=catalog.find((s:any)=>s.id===annotation.partId);if(!row)throw Error(`unknown station ${annotation.partId}`);
	const centers:TrackMapPoint[]=annotation.platformPaths.map((id:SourceReference)=>platformCenter(source(id), /[fFbB]/.test(annotations.sourcePaths[String(sourcePathId(id))].paint)));
	const p={x:centers.reduce((a,b)=>a+b.x,0)/centers.length,y:centers.reduce((a,b)=>a+b.y,0)/centers.length};
	stationPoints.set(row.id,p);
	topology.stations.push({id:`station:${row.id}`,stationId:row.complexId,partId:row.id,name:row.name,point:p,stopIds:[`${row.id}N`,`${row.id}S`]});
}
const provenance:any[]=[];
const junctions=(annotations.junctions??[]).map((j:any)=>{
	const points=source(j.sourcePath);
	return {...j,point:j.endpoint==='start'?points[0]:points.at(-1)!};
});
const emittedNodes=new Map<string,TrackMapPoint>();
for(const chain of annotations.chains) {
	for(const partId of Object.keys(chain.platformDirections??{})) {
		if(!chain.stationParts?.includes(partId)||!catalog.some((s:any)=>s.id===partId))throw Error(`platform direction alias requires explicit catalog stationParts: ${chain.id}/${partId}`);
		platformDirectionsFor(partId,chain.direction,chain.codes?.[partId]??chain.code,chain.platformDirections,observations);
	}
	const precision=railFlatteningTolerance(annotations.flatteningTolerance,chain.flatteningTolerance);
	const paths=chain.paths.map((ref:SourceReference)=>source(ref,precision));
	const overlaps:any[]=[];
	for(const index of chain.trimEndToNext??[]) {
		if(!paths[index+1])throw Error(`missing overlap successor ${chain.id}/${index}`);
		const overlapPrecision=Math.min(0.005,precision);
		paths[index]=source(chain.paths[index],overlapPrecision);
		const endpoint=paths[index+1][0],location=project(endpoint,paths[index]);
		overlaps.push({sourceIndex:index,nextSourceEndpoint:endpoint,projectionDistance:location.distance,flatteningTolerance:overlapPrecision});
		paths[index]=trimPathEnd(paths[index],endpoint);
	}
	for(const index of chain.trimStartFromPrevious??[]) {
		if(!Number.isInteger(index)||index<1||!paths[index])throw Error(`invalid head overlap index ${chain.id}/${index}`);
		const overlapPrecision=Math.min(0.005,precision);
		paths[index]=source(chain.paths[index],overlapPrecision);
		const endpoint=paths[index-1].at(-1)!,location=project(endpoint,paths[index]);
		overlaps.push({sourceIndex:index,kind:'head',previousSourceEndpoint:endpoint,projectionDistance:location.distance,flatteningTolerance:overlapPrecision});
		paths[index]=trimPathStart(paths[index],endpoint);
	}
	const rail=concatenatePaths(paths,chain.maxJoinGap);
	const stations=annotations.stations.filter((s:any)=>chain.stationParts?chain.stationParts.includes(s.partId):s.corridor===chain.corridor);
	const projected=stations.map((s:any)=>({...s,nodeId:`${chain.id}:${s.partId}`,...project(stationPoints.get(s.partId)!,rail)}));
	for(const j of junctions.filter((j:any)=>j.chains.includes(chain.id))) {
		const projection=project(j.point,rail);
		if(projection.distance>j.maxProjectionDistance)throw Error(`reviewed junction ${j.id} misses ${chain.id} by ${projection.distance}`);
		projected.push({...projection,partId:j.id,nodeId:`junction:${j.id}`,point:j.point,isJunction:true});
	}
	projected.sort((a:any,b:any)=>a.along-b.along);
	for(const p of projected) {
		if(p.distance>25)throw Error(`station ${p.partId} too far from ${chain.id}: ${p.distance}`);
		const nodeId=p.nodeId,existing=emittedNodes.get(nodeId);
		if(existing&&distance(existing,p.point)>1e-6)throw Error(`inconsistent shared node ${nodeId}`);
		if(!existing){topology.nodes.push({id:nodeId,point:p.point});emittedNodes.set(nodeId,p.point);}
		if(p.isJunction)continue;
		if((!chain.express||p.express)&&(!chain.platformParts||chain.platformParts.includes(p.partId))) {
			for(const direction of platformDirectionsFor(p.partId,chain.direction,chain.codes?.[p.partId]??chain.code,chain.platformDirections,observations))topology.platforms.push({id:`platform:${nodeId}:${direction}`,stopId:`${p.partId}${direction}`,trackCodes:[chain.codes?.[p.partId]??chain.code],nodeId});
		}
	}
	for(let i=1;i<projected.length;i++) {
		const a=projected[i-1],b=projected[i];
		const points=[a.point,...rail.slice(a.index+1,b.index+1),b.point].filter((p,j,all)=>j===0||distance(p,all[j-1])>1e-9);
		const north=chain.direction==='N';if(north)points.reverse();
		const from=north?b.nodeId:a.nodeId,to=north?a.nodeId:b.nodeId;
		topology.edges.push({id:`${chain.id}:${a.partId}-${b.partId}`,from,to,points,bidirectional:chain.bidirectional??false,revenue:true});
	}
		provenance.push({chain:chain.id,flatteningTolerance:precision,sourcePaths:chain.paths,reviewedOverlaps:overlaps,maximumJoinGap:Math.max(0,...paths.slice(1).map((p:TrackMapPoint[],i:number)=>distance(paths[i].at(-1)!,p[0]))),platformProjections:projected.filter((p:any)=>!p.isJunction).map((p:any)=>({partId:p.partId,distance:p.distance})),junctionProjections:projected.filter((p:any)=>p.isJunction).map((p:any)=>({junction:p.partId,distance:p.distance}))});
}
const mapped=new Set(topology.platforms.filter(p=>p.trackCodes.length).map(p=>p.stopId));
topology.coverage.mappedStopIds=[...mapped].sort();
topology.coverage.unresolvedStopIds=catalog.flatMap((s:any)=>[`${s.id}N`,`${s.id}S`]).filter((id:string)=>!mapped.has(id)).sort();
topology.coverage.notes.unshift(`PARTIAL: ${topology.stations.length}/${catalog.length} station parts anchored; ${mapped.size}/${catalog.length*2} directional stop IDs have a track crosswalk. Every other stop is explicitly unresolved. A mapped stop does not imply every possible platform, switch or operating move is covered.`);
const errors=validateTopology(topology);if(errors.length)throw Error(errors.join('\n'));
const crosswalks=topology.platforms.map(platform=>{
	const direct=observations.filter((o:any)=>o.stopId===platform.stopId&&platform.trackCodes.some(code=>o.actualTrack===code||o.scheduledTrack===code));
	const chainId=platform.nodeId.slice(0,platform.nodeId.lastIndexOf(':'));
	const witnesses=topology.platforms.filter(p=>p.nodeId.startsWith(`${chainId}:`)&&p.trackCodes.some(c=>platform.trackCodes.includes(c))).filter(p=>observations.some((o:any)=>o.stopId===p.stopId&&p.trackCodes.some(c=>o.actualTrack===c||o.scheduledTrack===c))).map(p=>p.stopId);
	if(!witnesses.length)throw Error(`track code has no observed witness on annotated rail: ${platform.id}`);
	return {platformId:platform.id,stopId:platform.stopId,trackCodes:platform.trackCodes,chain:chainId,basis:direct.length?'direct-feed-observation-and-source-rail':'continuous-source-rail-with-observed-code-elsewhere',observations:direct,witnessStopIds:[...new Set(witnesses)].sort()};
});
const routes=[...new Set<string>(catalog.flatMap((s:any)=>s.routes))].sort();
const anchored=new Set(topology.stations.map(s=>s.partId));
const observedPairs=new Map<string,{stopId:string;trackCode:string;routes:Set<string>}>();
for(const observation of observations)for(const trackCode of [observation.actualTrack,observation.scheduledTrack].filter(Boolean)) {
	const key=JSON.stringify([observation.stopId,trackCode]);
	const row=observedPairs.get(key)??{stopId:observation.stopId,trackCode,routes:new Set<string>()};
	row.routes.add(observation.route);observedPairs.set(key,row);
}
const observedEntries=[...observedPairs.values()].map(row=>{
	const accepted=topology.platforms.filter(p=>p.stopId===row.stopId&&p.trackCodes.includes(row.trackCode));
	const catalogued=topology.stations.some(s=>s.stopIds.includes(row.stopId));
	return {stopId:row.stopId,trackCode:row.trackCode,routes:[...row.routes].sort(),status:accepted.length?'mapped':'unresolved',reason:accepted.length?'reviewed source-rail crosswalk':catalogued?'physical rail/code assignment or operating direction unresolved':'stop ID absent from station catalog',platformIds:accepted.map(p=>p.id).sort()};
}).sort((a,b)=>a.stopId.localeCompare(b.stopId)||a.trackCode.localeCompare(b.trackCode));
const coverage={
	stationParts:catalog.length,
	anchoredStationParts:anchored.size,
	missingStationParts:catalog.filter((s:any)=>!anchored.has(s.id)).map((s:any)=>({partId:s.id,name:s.name,routes:s.routes})),
	directionalStopIds:catalog.length*2,
	mappedDirectionalStopIds:mapped.size,
	unresolvedDirectionalStopIds:topology.coverage.unresolvedStopIds.length,
	platformCrosswalks:crosswalks.length,
	observedStopTrackPairs:{total:observedEntries.length,mapped:observedEntries.filter(r=>r.status==='mapped').length,unresolved:observedEntries.filter(r=>r.status==='unresolved').length,entries:observedEntries},
	directlyObservedCrosswalks:crosswalks.filter(p=>p.observations.length).length,
	continuousRailCrosswalks:crosswalks.filter(p=>!p.observations.length).length,
	routes:routes.map(route=>{
		const rows=catalog.filter((s:any)=>s.routes.includes(route));
		return {
			route,stationParts:rows.length,
			anchoredStationParts:rows.filter((s:any)=>anchored.has(s.id)).length,
			mappedDirectionalStopIds:rows.reduce((n:number,s:any)=>n+Number(mapped.has(`${s.id}N`))+Number(mapped.has(`${s.id}S`)),0),
			directionalStopIds:rows.length*2,
		};
	}),
};
const out=new URL('../../data/track-map/nyc-2.6.8-v1.json',import.meta.url);
writeFileSync(out,JSON.stringify(topology,null,'\t')+'\n');
writeFileSync(new URL('../../data/track-map/provenance.json',import.meta.url),JSON.stringify({sourceSha256:expected,trackCodeEvidenceBoundary:'Feed observations contain stop and track strings, not physical PDF coordinates. Direct-feed provenance confirms the exact observed stop/code; the physical source-rail association remains an explicit reviewed annotation, with primary physical-code references recorded separately where available. Color or coordinate order alone is not proof.',flatteningTolerance:annotations.flatteningTolerance,chains:provenance,crosswalks},null,'\t')+'\n');
writeFileSync(new URL('../../data/track-map/coverage.json',import.meta.url),JSON.stringify(coverage,null,'\t')+'\n');
console.log(JSON.stringify({output:fileURLToPath(out),stations:topology.stations.length,nodes:topology.nodes.length,edges:topology.edges.length,platforms:topology.platforms.length,mappedStopIds:mapped.size,unresolvedStopIds:topology.coverage.unresolvedStopIds.length}));
