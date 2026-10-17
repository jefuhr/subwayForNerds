// Inspection aid only. Nearby paths are candidates, never accepted junctions or track codes.
import { readFileSync } from 'node:fs';
import { flattenCommands, project, selectSubpath } from './topology';
const [sourcePath,topologyPath,...parts]=process.argv.slice(2);
if(!sourcePath||!topologyPath||!parts.length)throw Error('usage: candidate-rails.ts extracted.json topology.json partId...');
const extraction=JSON.parse(readFileSync(sourcePath,'utf8'));
const topology=JSON.parse(readFileSync(topologyPath,'utf8'));
const paths=extraction.paths.filter((p:any)=>p.paint==='S'&&p.width===1).flatMap((p:any)=>{
	const count=p.commands.filter((c:any)=>c.op==='m').length;
	return Array.from({length:count},(_,subpath)=>({...p,subpath:count>1?subpath:undefined,points:flattenCommands(selectSubpath(p.commands,subpath))}));
});
const candidates=parts.map(partId=>{
	const station=topology.stations.find((s:any)=>s.partId===partId);if(!station)throw Error(`no anchor ${partId}`);
	const rails=paths.map((p:any)=>({sourcePathId:p.id,subpath:p.subpath,color:p.stroke,dash:p.dash,distance:project(station.point,p.points).distance,start:p.points[0],end:p.points.at(-1),commands:p.commands.length})).sort((a:any,b:any)=>a.distance-b.distance).slice(0,8);
	return {partId,name:station.name,point:station.point,rails};
});
console.log(JSON.stringify({warning:'Unreviewed proximity candidates only; intersections and endpoint proximity do not establish junctions.',candidates},null,'\t'));
