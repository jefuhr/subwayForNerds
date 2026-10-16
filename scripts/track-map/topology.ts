import type { TrackMapPoint, TrackMapTopology } from '../../shared/track-map';
export type Command = { op: string; p?: number[]; c1?: number[]; c2?: number[]; c?: number[] };
export type SourceReference = number | {pathId:number;subpath:number;reverse?:boolean};
export const sourcePathId = (ref:SourceReference) => typeof ref==='number'?Math.abs(ref):ref.pathId;
export function selectSubpath(commands:Command[],index:number):Command[] {
	if(!Number.isInteger(index)||index<0)throw Error('invalid source subpath index');
	const subpaths:Command[][]=[];
	for(const command of commands) {
		if(command.op==='m')subpaths.push([]);
		if(!subpaths.length)throw Error('source subpath does not begin with moveto');
		subpaths.at(-1)!.push(command);
	}
	if(!subpaths[index])throw Error(`missing source subpath ${index}`);
	return subpaths[index];
}
/** Rail-only refinement; station anchors keep their independently accepted default. */
export function railFlatteningTolerance(defaultTolerance:number,override?:number):number {
	const tolerance=override??defaultTolerance;
	if(!Number.isFinite(defaultTolerance)||defaultTolerance<=0||!Number.isFinite(tolerance)||tolerance<=0||tolerance>defaultTolerance)throw Error('rail flattening tolerance must be positive, finite and no coarser than the default');
	return tolerance;
}
export const distance = (a: TrackMapPoint, b: TrackMapPoint) => Math.hypot(a.x-b.x,a.y-b.y);
/** Filled platform outlines use area centroids; stroke markers use arc-length midpoints. */
export function platformCenter(points:TrackMapPoint[],filled:boolean):TrackMapPoint {
	if(!points.length)throw Error('empty platform path');
	if(filled) {
		let area2=0,x=0,y=0;
		for(let i=0;i<points.length;i++) {
			const a=points[i],b=points[(i+1)%points.length],cross=a.x*b.y-b.x*a.y;
			area2+=cross;x+=(a.x+b.x)*cross;y+=(a.y+b.y)*cross;
		}
		if(Math.abs(area2)>1e-8)return{x:x/(3*area2),y:y/(3*area2)};
	}
	const lengths=points.slice(1).map((p,i)=>distance(p,points[i]));
	let remaining=lengths.reduce((a,b)=>a+b,0)/2;
	for(let i=0;i<lengths.length;i++) {
		if(remaining<=lengths[i]&&lengths[i]>0) {
			const t=remaining/lengths[i];return{x:points[i].x+t*(points[i+1].x-points[i].x),y:points[i].y+t*(points[i+1].y-points[i].y)};
		}
		remaining-=lengths[i];
	}
	return points.at(-1)!;
}
const point = (p: number[]) => ({ x:p[0], y:p[1] });
const midpoint = (a: TrackMapPoint,b: TrackMapPoint) => ({x:(a.x+b.x)/2,y:(a.y+b.y)/2});
function segmentDistance(p: TrackMapPoint,a: TrackMapPoint,b: TrackMapPoint) {
	const d = (b.x-a.x)**2+(b.y-a.y)**2;
	const t = d ? Math.max(0,Math.min(1,((p.x-a.x)*(b.x-a.x)+(p.y-a.y)*(b.y-a.y))/d)) : 0;
	return distance(p,{x:a.x+t*(b.x-a.x),y:a.y+t*(b.y-a.y)});
}
/** Adaptive de Casteljau subdivision; the control hull bounds geometric error. */
export function flattenCommands(commands: Command[], tolerance = 0.05): TrackMapPoint[] {
	if (!(tolerance>0)) throw Error('positive flattening tolerance required');
	const result: TrackMapPoint[] = [];
	function curve(a:TrackMapPoint,b:TrackMapPoint,c:TrackMapPoint,d:TrackMapPoint,depth=0) {
		if (Math.max(segmentDistance(b,a,d),segmentDistance(c,a,d))<=tolerance) {result.push(d);return;}
		if (depth>=24) throw Error('Bezier subdivision limit');
		const ab=midpoint(a,b),bc=midpoint(b,c),cd=midpoint(c,d),abc=midpoint(ab,bc),bcd=midpoint(bc,cd),m=midpoint(abc,bcd);
		curve(a,ab,abc,m,depth+1); curve(m,bcd,cd,d,depth+1);
	}
	for (const cmd of commands) {
		if (cmd.op==='m') {if(result.length) throw Error('multiple subpaths require explicit separation');result.push(point(cmd.p!));continue;}
		const a=result.at(-1); if(!a) throw Error('path does not begin with moveto');
		if(cmd.op==='l') result.push(point(cmd.p!));
		else if(cmd.op==='c') curve(a,point(cmd.c1!),point(cmd.c2!),point(cmd.p!));
		else if(cmd.op==='v') curve(a,a,point(cmd.c!),point(cmd.p!));
		else if(cmd.op==='y') curve(a,point(cmd.c!),point(cmd.p!),point(cmd.p!));
		else if(cmd.op==='h') result.push(result[0]);
		else throw Error(`unsupported operator ${cmd.op}`);
	}
	return result.filter((p,i)=>i===0||distance(p,result[i-1])>1e-9);
}
/** Only caller-annotated chains join. Intersections and nearby rails never imply a junction. */
export function concatenatePaths(paths:TrackMapPoint[][],maxGap=0.03):TrackMapPoint[] {
	const result:TrackMapPoint[]=[];
	for(const path of paths) {
		if(!path.length) throw Error('empty source path');
		if(result.length) {
			const gap=distance(result.at(-1)!,path[0]);
			if(gap>maxGap) throw Error(`source endpoint gap ${gap} exceeds annotated tolerance ${maxGap}`);
			// Collapse only the approved source rounding seam; do not add a line over a gap.
			result.push(...path.slice(1));
		} else result.push(...path);
	}
	return result;
}
export function project(p:TrackMapPoint,points:TrackMapPoint[]) {
	let best={point:points[0],distance:Infinity,along:0,index:0},along=0;
	for(let i=1;i<points.length;i++) {
		const a=points[i-1],b=points[i],length=distance(a,b),dx=b.x-a.x,dy=b.y-a.y;
		const t=length?Math.max(0,Math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/(length*length))):0;
		const q={x:a.x+t*dx,y:a.y+t*dy},d=distance(p,q);
		if(d<best.distance) best={point:q,distance:d,along:along+t*length,index:i-1};
		along+=length;
	}
	return best;
}
/** Explicitly reviewed overlap only: clip to an endpoint already present in the next source path. */
export function trimPathEnd(points:TrackMapPoint[],endpoint:TrackMapPoint,maxDistance=0.03):TrackMapPoint[] {
	const location=project(endpoint,points);
	if(location.distance>maxDistance)throw Error(`source overlap misses existing rail by ${location.distance}`);
	return [...points.slice(0,location.index+1),endpoint];
}
/** Symmetric reviewed overlap: keep the suffix beginning at an existing previous-path endpoint. */
export function trimPathStart(points:TrackMapPoint[],endpoint:TrackMapPoint,maxDistance=0.03):TrackMapPoint[] {
	const location=project(endpoint,points);
	if(location.distance>maxDistance)throw Error(`source overlap misses existing rail by ${location.distance}`);
	return [endpoint,...points.slice(location.index+1)];
}
export function validateTopology(t:TrackMapTopology):string[] {
	const errors:string[]=[];
	function unique(items:{id:string}[],kind:string) {const seen=new Set<string>();for(const item of items){if(seen.has(item.id))errors.push(`duplicate ${kind} ${item.id}`);seen.add(item.id);}}
	for(const [kind,items] of Object.entries({station:t.stations,node:t.nodes,edge:t.edges,platform:t.platforms}))unique(items,kind);
	if(t.schemaVersion!==1||!t.mapVersion||!/^[0-9a-f]{64}$/.test(t.pdfSha256))errors.push('invalid source identity');
	if(!(t.page.width>0&&t.page.height>0&&Number.isFinite(t.page.width)&&Number.isFinite(t.page.height)))errors.push('invalid page');
	function bounds(p:TrackMapPoint,label:string) {if(!Number.isFinite(p.x)||!Number.isFinite(p.y)||p.x<0||p.y<0||p.x>t.page.width||p.y>t.page.height)errors.push(`bounds ${label}`);}
	const nodes=new Map(t.nodes.map(n=>[n.id,n])),used=new Set<string>();
	for(const n of t.nodes)bounds(n.point,n.id);
	for(const s of t.stations)bounds(s.point,s.id);
	for(const e of t.edges) {
		const a=nodes.get(e.from),b=nodes.get(e.to); used.add(e.from);used.add(e.to);
		if(!a||!b)errors.push(`edge missing node ${e.id}`);
		if(e.points.length<2)errors.push(`short edge ${e.id}`);
		if(a&&e.points.length&&!(distance(a.point,e.points[0])<=1e-6))errors.push(`endpoint mismatch ${e.id} from`);
		if(b&&e.points.length&&!(distance(b.point,e.points.at(-1)!)<=1e-6))errors.push(`endpoint mismatch ${e.id} to`);
		if(e.points.every((p,i)=>i===0||distance(p,e.points[0])<1e-6))errors.push(`zero length edge ${e.id}`);
		for(const p of e.points)bounds(p,e.id);
	}
	const stopIds=new Set(t.stations.flatMap(s=>s.stopIds)),mapped=new Set<string>(),crosswalk=new Set<string>();
	for(const p of t.platforms) {
		if(!nodes.has(p.nodeId))errors.push(`platform missing node ${p.id}`);
		if(!stopIds.has(p.stopId))errors.push(`platform unknown stop ${p.stopId}`);
		if(p.trackCodes.length) mapped.add(p.stopId);
		for(const code of p.trackCodes) {const key=`${p.stopId}:${code}`; if(!code||crosswalk.has(key))errors.push(`duplicate/empty crosswalk ${key}`);crosswalk.add(key);}
	}
	for(const n of t.nodes)if(!used.has(n.id))errors.push(`orphan node ${n.id}`);
	const declared=new Set(t.coverage.mappedStopIds),unresolved=new Set(t.coverage.unresolvedStopIds);
	if(declared.size!==t.coverage.mappedStopIds.length||unresolved.size!==t.coverage.unresolvedStopIds.length)errors.push('duplicate coverage');
	for(const id of declared)if(!mapped.has(id)||unresolved.has(id))errors.push(`coverage false mapped ${id}`);
	for(const id of mapped)if(!declared.has(id))errors.push(`coverage missing mapped ${id}`);
	for(const id of stopIds)if(!declared.has(id)&&!unresolved.has(id))errors.push(`coverage missing stop ${id}`);
	return errors;
}

export function platformDirectionsFor(
	partId:string,
	chainDirection:'N'|'S'|'B',
	code:string,
	overrides:Record<string,Array<'N'|'S'>>|undefined,
	observations:ReadonlyArray<{stopId:string;actualTrack?:string;scheduledTrack?:string}>,
):Array<'N'|'S'> {
	const aliases=overrides?.[partId];
	if(aliases===undefined)return chainDirection==='B'?['N','S']:[chainDirection];
	if(!Array.isArray(aliases)||!aliases.length||new Set(aliases).size!==aliases.length||aliases.some(d=>d!=='N'&&d!=='S'))throw Error(`platform directions must be unique N/S values: ${partId}`);
	for(const direction of aliases) {
		// The original direction already has the chain's reviewed physical-rail evidence.
		// Every added direction still needs its own exact stop/code observation.
		if(direction===chainDirection||chainDirection==='B')continue;
		if(!observations.some(o=>o.stopId===`${partId}${direction}`&&(o.actualTrack===code||o.scheduledTrack===code)))throw Error(`platform direction alias needs exact stop/code witness: ${partId}${direction}/${code}`);
	}
	return [...aliases];
}
