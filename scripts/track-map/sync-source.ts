// Copy exact selected native paths into annotations after a reviewed selector edit.
import { readFileSync, writeFileSync } from 'node:fs';
import { sourcePathId, type SourceReference } from './topology';
if(!process.argv[2])throw Error('usage: sync-source.ts extracted.json');
const path=new URL('../../data/track-map/annotations.json',import.meta.url);
const annotations=JSON.parse(readFileSync(path,'utf8'));
const extraction=JSON.parse(readFileSync(process.argv[2],'utf8'));
const refs:SourceReference[]=[...annotations.chains.flatMap((c:any)=>c.paths),...annotations.stations.flatMap((s:any)=>s.platformPaths),...(annotations.junctions??[]).map((j:any)=>j.sourcePath)];
const ids=[...new Set(refs.map(sourcePathId))].sort((a,b)=>a-b);
annotations.sourcePaths=Object.fromEntries(ids.map(id=>{
	const selected=extraction.paths[id];if(!selected||selected.id!==id)throw Error(`missing native path ${id}`);
	return [String(id),selected];
}));
writeFileSync(path,JSON.stringify(annotations,null,'\t')+'\n');
console.log(`Synchronized ${ids.length} exact native source paths; verify-source.ts must pass before acceptance.`);
