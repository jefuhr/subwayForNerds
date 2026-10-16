import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import type { TrackMapTopology } from '../shared/track-map';
import { validateTopology, flattenCommands, concatenatePaths, platformCenter, selectSubpath, trimPathEnd, platformDirectionsFor, railFlatteningTolerance, trimPathStart } from '../scripts/track-map/topology';

const fixture = (): TrackMapTopology => ({
	schemaVersion: 1, mapVersion: 'test', pdfSha256: 'a'.repeat(64), page: { width: 100, height: 100 }, attribution: 'test', sourceURL: 'https://example.test',
	stations: [{ id: 's', stationId: 's', partId: 'T01', name: 'test', point: { x: 10, y: 10 }, stopIds: ['T01N'] }],
	nodes: [{ id: 'a', point: { x: 0, y: 0 } }, { id: 'b', point: { x: 20, y: 20 } }],
	edges: [{ id: 'e', from: 'a', to: 'b', points: [{ x: 0, y: 0 }, { x: 20, y: 20 }], bidirectional: true, revenue: true }],
	platforms: [{ id: 'p', stopId: 'T01N', trackCodes: ['2'], nodeId: 'a' }], coverage: { mappedStopIds: ['T01N'], unresolvedStopIds: [], notes: [] },
});
test('accepts a consistent graph and rejects discontinuous endpoints, duplicates, invalid bounds and dangling platforms', () => {
	assert.deepEqual(validateTopology(fixture()), []);
	const bad = fixture();
	bad.edges[0].points[0].x = 2;
	bad.nodes.push({ id: 'a', point: { x: 101, y: NaN } });
	bad.platforms[0].nodeId = 'missing';
	const errors = validateTopology(bad).join('\n');
	assert.match(errors, /duplicate node/); assert.match(errors, /bounds/); assert.match(errors, /endpoint/); assert.match(errors, /missing node/);
});
test('rejects false coverage, unknown stations, overlapping partitions and orphan graph nodes', () => {
	const bad = fixture(); bad.coverage.unresolvedStopIds.push('T01N'); bad.coverage.mappedStopIds.push('T02S');
	bad.nodes.push({ id: 'unused', point: { x: 3, y: 4 } }); bad.platforms[0].stopId = 'unknown';
	const errors = validateTopology(bad).join('\n');
	assert.match(errors, /coverage/); assert.match(errors, /orphan/); assert.match(errors, /unknown stop/);
});
test('Bezier flattening preserves endpoints and bounds error, including PDF v and y operators', () => {
	const points = flattenCommands([{op:'m',p:[0,0]},{op:'c',c1:[0,100],c2:[100,100],p:[100,0]}],0.1);
	assert.deepEqual(points[0],{x:0,y:0}); assert.deepEqual(points.at(-1),{x:100,y:0});
	assert.ok(points.length > 20); assert.ok(Math.max(...points.map(p => p.y)) <= 75);
	assert.deepEqual(flattenCommands([{op:'m',p:[0,0]},{op:'v',c:[5,10],p:[10,10]},{op:'y',c:[15,0],p:[20,0]}]).at(-1),{x:20,y:0});
});
test('joining is explicit and rejects gaps instead of inventing connecting geometry', () => {
	assert.throws(() => concatenatePaths([[{x:0,y:0},{x:1,y:1}],[{x:5,y:5},{x:9,y:9}]],0.03), /gap/);
});
test('geometric crossings do not create graph junctions', () => {
	const t = fixture(); t.nodes.push({id:'c',point:{x:0,y:20}},{id:'d',point:{x:20,y:0}});
	t.edges.push({id:'crossing',from:'c',to:'d',points:[{x:0,y:20},{x:20,y:0}],bidirectional:true,revenue:true});
	assert.deepEqual(validateTopology(t),[]); assert.equal(t.nodes.length,4);
});
test('canonical data has exact source identity, honest subway coverage and source-aligned L plus four distinct Brighton rails', () => {
	const t: TrackMapTopology = JSON.parse(readFileSync(new URL('../data/track-map/nyc-2.6.8-v1.json',import.meta.url),'utf8'));
	assert.deepEqual(validateTopology(t),[]);
	assert.equal(t.pdfSha256,'b28f75397b2e7b6ba0b67db6ea2181800baa0254a48261252f3d55c4f2b17c71');
	assert.deepEqual(t.page,{width:7344,height:11540.6});
	const catalog = JSON.parse(readFileSync(new URL('../data/stations.json',import.meta.url),'utf8')).filter((s:any)=>!s.routes.includes('SIR'));
	assert.deepEqual([...t.coverage.mappedStopIds,...t.coverage.unresolvedStopIds].sort(),catalog.flatMap((s:any)=>[`${s.id}N`,`${s.id}S`]).sort());
	assert.ok(t.coverage.unresolvedStopIds.includes('S01N')||t.coverage.mappedStopIds.includes('S01N'),'Franklin shuttle must be included');
	assert.ok(![...t.coverage.mappedStopIds,...t.coverage.unresolvedStopIds].includes('S31N'),'SIR must be excluded');
	assert.equal(t.stations.filter(s=>s.partId.startsWith('L')).length,24);
	assert.equal(t.coverage.mappedStopIds.filter(id=>id.startsWith('L')).length,48);
	const codes = t.platforms.filter(p=>p.stopId==='D35S'||p.stopId==='D35N').flatMap(p=>p.trackCodes);
	assert.deepEqual([...new Set(codes)].sort(),['A1','A2','A3','A4']);
	assert.ok(t.coverage.unresolvedStopIds.length>0,'partial source annotation must not claim full network');
});

const canonical = ():TrackMapTopology => JSON.parse(readFileSync(new URL('../data/track-map/nyc-2.6.8-v1.json',import.meta.url),'utf8'));
function platform(t:TrackMapTopology,stop:string,code:string) {
	const p=t.platforms.find(p=>p.stopId===stop&&p.trackCodes.includes(code));assert.ok(p,`missing ${stop}/${code}`);return p.nodeId;
}
function reachable(t:TrackMapTopology,from:string,to:string) {
	const seen=new Set([from]),queue=[from];
	while(queue.length){const id=queue.shift()!;if(id===to)return true;for(const e of t.edges){const next=e.from===id?e.to:e.bidirectional&&e.to===id?e.from:undefined;if(next&&!seen.has(next)){seen.add(next);queue.push(next);}}}
	return false;
}
test('L has continuous directed journeys on both separate rails and never switches tracks at a crossing',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'L01S','1'),platform(t,'L29S','1')));
	assert.ok(reachable(t,platform(t,'L29N','2'),platform(t,'L01N','2')));
	assert.ok(!reachable(t,platform(t,'L29S','1'),platform(t,'L01S','1')));
	assert.ok(!reachable(t,platform(t,'L01S','1'),platform(t,'L29N','2')));
	assert.ok(!reachable(t,platform(t,'G29S','E1'),platform(t,'L10S','1')),'Crosstown/Canarsie grade crossing is not a junction');
});
test('Brighton express paths pass local-only stations without gaining local platforms or rail changes',()=>{
	const t=canonical();
	for(const code of ['A1','A3'])assert.ok(reachable(t,platform(t,'D28S',code),platform(t,'D39S',code)));
	for(const code of ['A2','A4'])assert.ok(reachable(t,platform(t,'D39N',code),platform(t,'D28N',code)));
	assert.ok(!t.platforms.some(p=>p.stopId.startsWith('D29')&&p.trackCodes.some(c=>['A3','A4'].includes(c))));
	assert.ok(!reachable(t,platform(t,'D28S','A1'),platform(t,'D39S','A3')));
});
test('reversible rails support both directions without joining parallel shuttle tracks',()=>{
	const t=canonical();
	for(const code of ['1','4']) {
		const a=platform(t,'902S',code),b=platform(t,'901N',code);
		assert.ok(reachable(t,a,b));assert.ok(reachable(t,b,a));
	}
	assert.ok(!reachable(t,platform(t,'902S','1'),platform(t,'901N','4')));
	assert.ok(reachable(t,platform(t,'S01S','O2'),platform(t,'S03N','O2')));
	assert.ok(reachable(t,platform(t,'S03S','O2'),platform(t,'S01N','O2')));
	assert.ok(reachable(t,platform(t,'712N','M'),platform(t,'707N','M')));
	assert.ok(reachable(t,platform(t,'707S','M'),platform(t,'712S','M')));
	assert.ok(!t.platforms.some(p=>p.stopId==='710N'&&p.trackCodes.includes('M')),'an observed M code at a local-only station cannot invent a platform');
});
test('anchor-only stations remain unresolved and all mappings belong to the source catalog complex',()=>{
	const t=canonical(),rows=JSON.parse(readFileSync(new URL('../data/stations.json',import.meta.url),'utf8'));
	for(const station of t.stations) {
		const row=rows.find((r:any)=>r.id===station.partId);assert.ok(row);assert.equal(station.stationId,row.complexId);
		for(const id of station.stopIds)if(!t.platforms.some(p=>p.stopId===id))assert.ok(t.coverage.unresolvedStopIds.includes(id));
	}
	assert.ok(t.stations.some(s=>s.partId==='R45'),'broad network anchors must not disappear when their rail is unresolved');
	assert.ok(t.coverage.unresolvedStopIds.includes('H01S'),'an anchor does not fabricate a nonexistent southbound passenger platform');
});
test('Broadway-Seventh Avenue trunk retains four rails and express platforms only at express stops',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'121S','1'),platform(t,'137S','1')));
	assert.ok(reachable(t,platform(t,'137N','4'),platform(t,'121N','4')));
	assert.ok(reachable(t,platform(t,'123S','2'),platform(t,'137S','2')));
	assert.ok(reachable(t,platform(t,'137N','3'),platform(t,'123N','3')));
	assert.ok(!t.platforms.some(p=>p.stopId.startsWith('129')&&p.trackCodes.some(c=>['2','3'].includes(c))));
	assert.ok(!reachable(t,platform(t,'123S','1'),platform(t,'137S','2')));
});
test('station parts never reuse another part\'s source platform paths or silently equate stacked stations',()=>{
	const a=JSON.parse(readFileSync(new URL('../data/track-map/annotations.json',import.meta.url),'utf8'));
	const used=new Map<number,string>();
	for(const s of a.stations)for(const id of s.platformPaths){assert.ok(!used.has(id),`${s.partId} reuses source platform ${id} from ${used.get(id)}`);used.set(id,s.partId);}
	const cityHall=a.stations.find((s:any)=>s.partId==='R24');assert.deepEqual(cityHall.platformPaths,[7951]);
	const essex=a.stations.find((s:any)=>s.partId==='M18');assert.deepEqual(essex.platformPaths,[8295,8297]);
});
test('every subway station part has a main-map source anchor while unannotated tracks stay unresolved',()=>{
	const t=canonical();
	const catalog=JSON.parse(readFileSync(new URL('../data/stations.json',import.meta.url),'utf8')).filter((s:any)=>!s.routes.includes('SIR'));
	assert.equal(t.stations.length,475);
	assert.deepEqual(t.stations.map(s=>s.partId).sort(),catalog.map((s:any)=>s.id).sort());
	assert.ok(t.coverage.unresolvedStopIds.includes('D43N'),'a Coney Island anchor must not claim unreviewed terminal faces');
});

test('filled platform polygons use area centroids rather than a perimeter endpoint',()=>{
	const rectangle=[{x:0,y:0},{x:10,y:0},{x:10,y:2},{x:0,y:2},{x:0,y:0}];
	assert.deepEqual(platformCenter(rectangle,true),{x:5,y:1});
	assert.deepEqual(platformCenter([{x:0,y:0},{x:10,y:0}],false),{x:5,y:0});
});
test('IRT outer terminals extend existing rails and Lenox joins White Plains only at reviewed physical merges',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'101S','1'),platform(t,'137S','1')));
	assert.ok(reachable(t,platform(t,'137N','4'),platform(t,'101N','4')));
	assert.ok(reachable(t,platform(t,'201S','2'),platform(t,'137S','2')));
	assert.ok(reachable(t,platform(t,'137N','3'),platform(t,'201N','3')));
	assert.ok(reachable(t,platform(t,'301S','1'),platform(t,'137S','2')));
	assert.ok(reachable(t,platform(t,'137N','3'),platform(t,'301N','4')));
	assert.ok(!reachable(t,platform(t,'201S','2'),platform(t,'301N','4')),'the Lenox junction is not a cross-track teleport');
	assert.ok(reachable(t,platform(t,'501S','1'),platform(t,'505S','1')));
	assert.ok(reachable(t,platform(t,'505N','2'),platform(t,'501N','2')));
	assert.ok(reachable(t,platform(t,'601S','2'),platform(t,'619S','2')));
	assert.ok(reachable(t,platform(t,'619N','3'),platform(t,'601N','3')));
});
test('Jerome and Nostrand branches retain independent directed source rails',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'401S','1'),platform(t,'416S','1')));
	assert.ok(reachable(t,platform(t,'416N','4'),platform(t,'401N','4')));
	assert.ok(reachable(t,platform(t,'241S','2'),platform(t,'247S','2')));
	assert.ok(reachable(t,platform(t,'247N','3'),platform(t,'241N','3')));
	assert.ok(!reachable(t,platform(t,'241S','2'),platform(t,'241N','3')));
});

test('source subpaths require explicit selection and are never silently joined across moveto operators',()=>{
	const commands=[{op:'m',p:[0,0]},{op:'l',p:[2,0]},{op:'m',p:[50,50]},{op:'l',p:[52,50]}];
	assert.throws(()=>flattenCommands(commands),/multiple subpaths/);
	assert.deepEqual(flattenCommands(selectSubpath(commands,1)),[{x:50,y:50},{x:52,y:50}]);
	assert.throws(()=>selectSubpath(commands,2),/subpath/);
});
test('Broadway local trains reach the current South Ferry terminal on explicitly selected source subpaths',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'101S','1'),platform(t,'142S','1')));
	assert.ok(reachable(t,platform(t,'142N','4'),platform(t,'101N','4')));
	assert.ok(!reachable(t,platform(t,'142S','1'),platform(t,'142N','4')),'terminal track reversal is not inferred from nearby rails');
});
test('Brooklyn IRT rails preserve express/local identity and do not bridge the unpainted Utica-Sutter transition',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'228S','2'),platform(t,'257S','1')));
	assert.ok(reachable(t,platform(t,'250N','4'),platform(t,'228N','3')));
	assert.ok(reachable(t,platform(t,'257N','4'),platform(t,'251N','4')));
	assert.ok(!reachable(t,platform(t,'257N','4'),platform(t,'250N','4')),'a recorded source gap must remain disconnected');
	assert.ok(reachable(t,platform(t,'234S','2'),platform(t,'250S','2')));
	assert.ok(reachable(t,platform(t,'250N','3'),platform(t,'234N','3')));
	assert.ok(!t.platforms.some(p=>p.stopId==='236S'&&p.trackCodes.includes('2')),'Bergen Street has no express platform');
});

test('reviewed overlapping source paths can be clipped at a real endpoint without extending over a gap',()=>{
	assert.deepEqual(trimPathEnd([{x:0,y:0},{x:10,y:0}],{x:9,y:0}),[{x:0,y:0},{x:9,y:0}]);
	assert.throws(()=>trimPathEnd([{x:0,y:0},{x:10,y:0}],{x:12,y:0}),/overlap/);
});

test('Rockaway branches join only reviewed same-direction Liberty and Hammels nodes',()=>{
	const t=canonical();
	for(const terminal of ['A65','H11','H15']) {
		const code=terminal==='A65'?'K1':'F3';
		assert.ok(reachable(t,platform(t,'A57S','K1'),platform(t,`${terminal}S`,code)));
		assert.ok(reachable(t,platform(t,`${terminal}N`,terminal==='A65'?'K2':'F4'),platform(t,'A57N','K2')));
	}
	assert.ok(reachable(t,platform(t,'H02S','F1'),platform(t,'H04S','F3')));
	assert.ok(!reachable(t,platform(t,'H11S','F3'),platform(t,'H15S','F3')),'the non-revenue east-west chord is not a passenger connection');
	assert.ok(!t.platforms.some(p=>p.stopId==='H01S'),'Aqueduct Racetrack has only a northbound passenger platform');
	assert.ok(!reachable(t,platform(t,'H04S','F3'),platform(t,'H04N','F4')),'Hammels crossings do not join opposite rails');
});

test('Rogers explicitly connects Nostrand to same-direction local and express rails without cross-track teleports',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'239S','1'),platform(t,'247S','2')));
	assert.ok(reachable(t,platform(t,'239S','2'),platform(t,'247S','2')));
	assert.ok(reachable(t,platform(t,'247N','3'),platform(t,'239N','4')));
	assert.ok(reachable(t,platform(t,'247N','3'),platform(t,'239N','3')));
	assert.ok(!reachable(t,platform(t,'247S','2'),platform(t,'247N','3')));
});

test('Lexington preserves local platforms across stacked levels and source gaps between fragments',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'621S','2'),platform(t,'631S','1')));
	assert.ok(reachable(t,platform(t,'631N','4'),platform(t,'622N','4')));
	assert.ok(reachable(t,platform(t,'632S','1'),platform(t,'640S','1')));
	assert.ok(reachable(t,platform(t,'640N','4'),platform(t,'636N','4')));
	assert.ok(reachable(t,platform(t,'635S','2'),platform(t,'247S','2')));
	assert.ok(reachable(t,platform(t,'247N','3'),platform(t,'635N','3')));
	assert.ok(!t.platforms.some(p=>p.stopId==='625S'&&p.trackCodes.includes('2')),'96 Street has no lower-level express platform');
	assert.ok(!reachable(t,platform(t,'631S','1'),platform(t,'632S','1')),'Grand Central source gaps are not bridged');
});

test('Queens Boulevard keeps four parallel rails and records unpainted Elmhurst transitions as separate fragments',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'G05S','A1'),platform(t,'G08S','D3')));
	assert.ok(reachable(t,platform(t,'G08N','D4'),platform(t,'G05N','A2')));
	assert.ok(reachable(t,platform(t,'G08S','D1'),platform(t,'G13S','D1')));
	assert.ok(reachable(t,platform(t,'G13N','D2'),platform(t,'G08N','D2')));
	assert.ok(reachable(t,platform(t,'G14S','D3'),platform(t,'D14S','D3')));
	assert.ok(reachable(t,platform(t,'F11N','D4'),platform(t,'G14N','D4')));
	assert.ok(!t.platforms.some(p=>p.stopId==='G09S'&&p.trackCodes.includes('D3')),'67 Avenue has no express platform');
	assert.ok(!reachable(t,platform(t,'G13S','D1'),platform(t,'G14S','D1')),'Elmhurst painted gap remains disconnected');
});

test('Fulton express rails connect to Rockaway only through reviewed Hoyt branches and preserve local gaps',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'A31S','A3'),platform(t,'H11S','F3')));
	assert.ok(reachable(t,platform(t,'H15N','F4'),platform(t,'A32N','A4')));
	assert.ok(reachable(t,platform(t,'A43S','A1'),platform(t,'A45S','A1')));
	assert.ok(reachable(t,platform(t,'A47S','A1'),platform(t,'A55S','A1')));
	assert.ok(!reachable(t,platform(t,'A45S','A1'),platform(t,'A47S','A1')),'Nostrand local source gaps remain disconnected');
	assert.ok(!reachable(t,platform(t,'A42S','A3'),platform(t,'G36N','E2')),'blue and green Hoyt rails cross without a junction');
	const annotations=JSON.parse(readFileSync(new URL('../data/track-map/annotations.json',import.meta.url),'utf8'));
	assert.deepEqual(annotations.stations.find((s:any)=>s.partId==='A47').platformPaths,[5628,5629],'Kingston centroid includes both offset side platforms');
});


test('direction-label aliases require exact witnesses and share one physical node without reversing the rail',()=>{
	const observations=[{stopId:'T01N',actualTrack:'J1',scheduledTrack:''},{stopId:'T01S',actualTrack:'',scheduledTrack:'J1'}];
	const directions=platformDirectionsFor('T01','N','J1',{T01:['N','S']},observations);
	assert.deepEqual(directions,['N','S']);
	assert.throws(()=>platformDirectionsFor('T01','N','J2',{T01:['N','S']},observations),/exact stop\/code witness/);
	assert.throws(()=>platformDirectionsFor('T01','N','J1',{T01:['N','N']},observations),/unique/);
	const t=fixture();t.edges[0].bidirectional=false;t.stations[0].stopIds=['T01N','T01S'];
	t.platforms=directions.map(d=>({id:`p-${d}`,stopId:`T01${d}`,trackCodes:['J1'],nodeId:'a'}));
	t.coverage.mappedStopIds=['T01N','T01S'];
	assert.deepEqual(validateTopology(t),[]);
	assert.equal(t.edges.length,1);
	assert.equal(platform(t,'T01N','J1'),platform(t,'T01S','J1'));
	assert.ok(reachable(t,'a','b'));assert.ok(!reachable(t,'b','a'));
});

test('adding a directly observed direction alias preserves an existing continuous-rail default direction',()=>{
	const observations=[{stopId:'T01N',actualTrack:'M'}];
	assert.deepEqual(platformDirectionsFor('T01','S','M',{T01:['N','S']},observations),['N','S']);
	assert.throws(()=>platformDirectionsFor('T01','S','M',{T01:['N','S']},[]),/exact stop\/code witness/);
});

test('Fourth Avenue and Sea Beach preserve separate passenger tracks, express platforms and recorded seams',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'R29S','F1'),platform(t,'R41S','F1')));
	assert.ok(reachable(t,platform(t,'R45N','F2'),platform(t,'R29N','F2')));
	assert.ok(reachable(t,platform(t,'B23N','D2'),platform(t,'R31N','F4')));
	assert.ok(reachable(t,platform(t,'R31S','F3'),platform(t,'R36S','F3')));
	assert.ok(!t.platforms.some(p=>p.stopId==='R32S'&&p.trackCodes.includes('F3')));
	assert.ok(reachable(t,platform(t,'N02S','E1'),platform(t,'N04S','E1')));
	assert.ok(reachable(t,platform(t,'N10N','E2'),platform(t,'N04N','E2')));
	assert.ok(!reachable(t,platform(t,'N04S','E1'),platform(t,'N05S','E1')),'reviewed source seam exceeds0.03 and stays disconnected');
	assert.ok(!reachable(t,platform(t,'N04S','E1'),platform(t,'B16S','D1')),'New Utrecht crossing is not a junction');
});


test('CPW and Eighth Avenue local rails match the primary NYCT physical code anchor and remain separate',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'A09S','A1'),platform(t,'E01S','A1')));
	assert.ok(reachable(t,platform(t,'A31N','A2'),platform(t,'A09N','A2')));
	assert.ok(reachable(t,platform(t,'E01N','A2'),platform(t,'A32N','A2')));
	assert.ok(!reachable(t,platform(t,'A09S','A1'),platform(t,'A09N','A2')));
	assert.ok(!reachable(t,platform(t,'A32N','A2'),platform(t,'A31N','A2')),'the14Street northbound source gap remains unresolved');
	assert.ok(!t.platforms.some(p=>p.stopId==='A36S'&&p.trackCodes.includes('A1')),'Chambers and WTC are distinct platform groups');
});

test('Second Avenue, 63 Street, Culver and Brighton extensions preserve codes and platform roles',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'Q05S','S1'),platform(t,'Q01S','H1')));
	assert.ok(reachable(t,platform(t,'Q03N','S2'),platform(t,'Q05N','S2')));
	assert.ok(reachable(t,platform(t,'B04S','T1'),platform(t,'B10S','B5')));
	assert.ok(reachable(t,platform(t,'B06N','T2'),platform(t,'B04N','T2')));
	assert.ok(reachable(t,platform(t,'F29S','B1'),platform(t,'F39S','B1')));
	assert.ok(reachable(t,platform(t,'F39N','B2'),platform(t,'F29N','B2')));
	assert.ok(reachable(t,platform(t,'D26S','A3'),platform(t,'D42S','A3')));
	assert.ok(reachable(t,platform(t,'D42N','A4'),platform(t,'D26N','A4')));
	assert.ok(!t.platforms.some(p=>p.stopId==='R18S'&&p.trackCodes.includes('A3')),'28Street has no Broadway express platform');
});

test('Essex physical anchor carries Nassau and Broadway codes with witnessed J/M suffix aliases',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'J27S','J2'),platform(t,'M23S','R1')));
	assert.ok(reachable(t,platform(t,'M23N','R2'),platform(t,'M19N','J4')));
	assert.equal(platform(t,'M11N','J2'),platform(t,'M11S','J2'));
	assert.equal(platform(t,'M16N','J1'),platform(t,'M16S','J1'));
	assert.ok(!reachable(t,platform(t,'M18S','J1'),platform(t,'M16N','J1')),'Williamsburg source seam remains disconnected');
	assert.ok(!reachable(t,platform(t,'M11S','J2'),platform(t,'M11S','J1')),'aliases do not reverse or switch physical rails');
	assert.ok(reachable(t,platform(t,'M16S','J1'),platform(t,'M01S','M1')));
});

test('Inwood and CPW express rails preserve the 59 Street physical branches and dashed source gaps',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'A02S','A3'),platform(t,'A09S','A3')));
	assert.ok(reachable(t,platform(t,'A15N','A4'),platform(t,'A02N','A4')));
	assert.ok(reachable(t,platform(t,'A12S','A3'),platform(t,'A28S','A3')));
	assert.ok(reachable(t,platform(t,'A28N','A4'),platform(t,'A24N','A4')));
	assert.ok(!reachable(t,platform(t,'A09S','A3'),platform(t,'A12S','A3')),'168 Street dashed vector seam stays disconnected');
	assert.ok(!reachable(t,platform(t,'A24N','A4'),platform(t,'A15N','A4')),'103 Street source gaps are not synthetic rails');
	assert.ok(!t.platforms.some(p=>p.stopId==='A10S'&&p.trackCodes.includes('A3')));
});

test('every documented source gap has a unique identity and an honest measured distance',()=>{
	const ledger=JSON.parse(readFileSync(new URL('../data/track-map/unresolved-geometry.json',import.meta.url),'utf8'));
	const ids=new Set();
	for(const gap of ledger.gaps) {
		assert.ok(!ids.has(gap.id));ids.add(gap.id);
		assert.ok(gap.evidence&&gap.impact&&gap.corridor);
		assert.equal(gap.sourceEndpoints.length,2);
		const [a,b]=gap.sourceEndpoints;
		assert.ok(gap.distance>0.03);
		assert.ok(Math.abs(Math.hypot(a[0]-b[0],a[1]-b[1])-gap.distance)<1e-8,gap.id);
	}
});

test('Culver local rails continue through the G-colored section without snapping to express tracks',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'F20S','B1'),platform(t,'F39S','B1')));
	assert.ok(reachable(t,platform(t,'F39N','B2'),platform(t,'F20N','B2')));
	assert.ok(!reachable(t,platform(t,'F27S','B1'),platform(t,'F27N','B2')));
});

test('Franklin shuttle uses explicit single-track and Prospect Park branches with separate Botanic Garden rails',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'S01S','O2'),platform(t,'S04S','O1')));
	assert.ok(reachable(t,platform(t,'S04S','O1'),platform(t,'D26S','A2')));
	assert.ok(reachable(t,platform(t,'D26N','A2'),platform(t,'S04N','O2')));
	assert.ok(reachable(t,platform(t,'S04N','O2'),platform(t,'S01N','O2')));
	assert.equal(platform(t,'D26N','A2'),platform(t,'D26S','A2'));
	assert.ok(!t.platforms.some(p=>p.stopId==='S04S'&&p.trackCodes.includes('O2')));
});

test('Concourse outer rails match primary westC1 eastC2 evidence and preserve Bedford platform identity',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'D13N','C2'),platform(t,'D01N','C2')));
	assert.ok(reachable(t,platform(t,'D04S','C1'),platform(t,'D13S','C1')));
	assert.ok(reachable(t,platform(t,'D01S','C1'),platform(t,'D03S','C1')));
	assert.ok(reachable(t,platform(t,'A15N','A4'),platform(t,'D01N','C2')));
	assert.ok(reachable(t,platform(t,'D13S','C1'),platform(t,'A15S','A1')));
	assert.ok(!reachable(t,platform(t,'D03S','C1'),platform(t,'D04S','C1')),'Bedford physical reorder remains an explicit traversal limitation');
	assert.ok(!t.platforms.some(p=>p.stopId==='D03S'&&p.nodeId.startsWith('concourse-lower-C1:')),'center Bedford rail is not assigned outerC1');
});

test('Broadway local fragments retain track code transitions and exact Court Street through rails',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'R45N','F2'),platform(t,'R09N','G2')));
	assert.ok(reachable(t,platform(t,'R11S','G1'),platform(t,'R24S','B1')));
	assert.ok(reachable(t,platform(t,'R25S','B1'),platform(t,'R27S','B1')));
	assert.ok(reachable(t,platform(t,'R28S','B1'),platform(t,'R41S','F1')));
	assert.ok(!reachable(t,platform(t,'R27S','B1'),platform(t,'R28S','B1')),'East River painted breaks remain explicit');
	assert.ok(!reachable(t,platform(t,'R09N','G2'),platform(t,'R01N','G2')),'Queensboro/Astoria source gap is not bridged');
});


test('per-chain precision can refine rail curves without loosening the global default or seam threshold',()=>{
	assert.equal(railFlatteningTolerance(0.05),0.05);
	assert.equal(railFlatteningTolerance(0.05,0.005),0.005);
	for(const value of [0,-0.005,NaN,Infinity,0.1])assert.throws(()=>railFlatteningTolerance(0.05,value),/rail flattening tolerance/);
	assert.throws(()=>concatenatePaths([[{x:0,y:0},{x:1,y:0}],[{x:1.031,y:0},{x:2,y:0}]],0.03),/gap/);
});

test('observed code coverage distinguishes mapped directions from missing alternate physical tracks',()=>{
	const read=(p:string)=>JSON.parse(readFileSync(new URL(`../data/track-map/${p}`,import.meta.url),'utf8'));
	const coverage=read('coverage.json'),evidence=read('track-code-evidence.json'),t=canonical();
	const expected=new Set(evidence.snapshots.flatMap((s:any)=>s.observations.flatMap((o:any)=>[o.actualTrack,o.scheduledTrack].filter(Boolean).map((code:string)=>`${o.stopId}:${code}`))));
	const rows=coverage.observedStopTrackPairs.entries;
	assert.equal(rows.length,expected.size);
	assert.deepEqual(new Set(rows.map((r:any)=>`${r.stopId}:${r.trackCode}`)),expected);
	for(const row of rows)assert.equal(row.status==='mapped',t.platforms.some(p=>p.stopId===row.stopId&&p.trackCodes.includes(row.trackCode)));
	assert.equal(coverage.observedStopTrackPairs.mapped+coverage.observedStopTrackPairs.unresolved,expected.size);
	assert.equal(rows.find((r:any)=>r.stopId==='H19N'&&r.trackCode==='F6').reason,'stop ID absent from station catalog');
	assert.ok(rows.some((r:any)=>r.status==='unresolved'&&t.coverage.mappedStopIds.includes(r.stopId)),'one crosswalk must not imply every observed track is supported');
});


test('reviewed head overlaps clip an existing rail at the preceding source endpoint without extending it',()=>{
	const points=[{x:0,y:0},{x:5,y:0},{x:10,y:0}];
	assert.deepEqual(trimPathStart(points,{x:2,y:0}),[{x:2,y:0},{x:5,y:0},{x:10,y:0}]);
	assert.throws(()=>trimPathStart(points,{x:2,y:0.031}),/overlap/);
	assert.deepEqual(points,[{x:0,y:0},{x:5,y:0},{x:10,y:0}]);
});

test('Jamaica paired outer rails have witnessed codes while Alabama and Crescent gaps remain disconnected',()=>{
	const t=canonical();
	assert.ok(reachable(t,platform(t,'J24N','J1'),platform(t,'J12N','J1')));
	assert.ok(reachable(t,platform(t,'J12S','J2'),platform(t,'J19S','J2')));
	assert.ok(reachable(t,platform(t,'J20S','J2'),platform(t,'J24S','J2')));
	assert.ok(!reachable(t,platform(t,'J19S','J2'),platform(t,'J20S','J2')));
	assert.ok(!reachable(t,platform(t,'J24S','J2'),platform(t,'J27S','J2')));
});
