// Unreviewed endpoint-chain candidate. Ambiguities stop traversal; intersections are ignored.
import { readFileSync } from 'node:fs';
import { flattenCommands, distance, selectSubpath, type SourceReference } from './topology';
const [sourcePath,...prefix]=process.argv.slice(2);
function reference(token:string):SourceReference {
	if(!/^-?[1-9]\d*(?::\d+)?$/.test(token))throw Error(`invalid source selector ${token}`);
	const reverse=token.startsWith('-'),[id,subpath]=token.replace(/^-/,'').split(':').map(Number);
	return subpath===undefined?(reverse?-id:id):{pathId:id,subpath,reverse};
}
if(!sourcePath||!prefix.length)throw Error('usage: trace-candidate.ts extracted.json signedPathId[:subpath]...');
prefix.forEach(reference);
const extraction=JSON.parse(readFileSync(sourcePath,'utf8'));
const paths=extraction.paths.filter((p:any)=>p.paint==='S'&&p.width===1).flatMap((p:any)=>{
	const count=p.commands.filter((c:any)=>c.op==='m').length;
	return Array.from({length:count},(_,subpath)=>({...p,key:count===1?String(p.id):`${p.id}:${subpath}`,points:flattenCommands(selectSubpath(p.commands,subpath))}));
});
const trace=[...prefix];
let candidates:any[]=[],end:any;
for(let step=0;step<200;step++) {
	const token=trace.at(-1)!,key=token.replace(/^-/,'');
	const p=paths.find((p:any)=>p.key===key);if(!p)throw Error(`unsupported source selector ${token}`);
	end=token.startsWith('-')?p.points[0]:p.points.at(-1);
	candidates=paths.filter((p:any)=>!trace.some(token=>token.replace(/^-/,'')===p.key)).flatMap((p:any)=>{
		const length=p.points.slice(1).reduce((n:number,q:any,i:number)=>n+distance(q,p.points[i]),0);
		return [{id:p.key,gap:distance(end,p.points[0]),length,color:p.stroke,dash:p.dash},{id:`-${p.key}`,gap:distance(end,p.points.at(-1)),length,color:p.stroke,dash:p.dash}];
	}).sort((a:any,b:any)=>a.gap-b.gap);
	const matches=candidates.filter(c=>c.gap<=0.03&&JSON.stringify(c.color)===JSON.stringify(p.stroke));
	if(matches.length!==1)break;
	trace.push(matches[0].id);
}
console.log(JSON.stringify({warning:'Unreviewed source-path chain only. Prefix is caller-selected; automatic continuation stops at ambiguous same-color endpoints. Separate moveto subpaths are explicit selectors, never implicitly joined.',trace:trace.map(reference),selectors:trace,end,candidates:candidates.slice(0,8)},null,'\t'));
