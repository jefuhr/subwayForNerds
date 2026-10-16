import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const extraction=JSON.parse(readFileSync(process.argv[2]??'artifacts/track-map/extracted.json','utf8'));
const annotations=JSON.parse(readFileSync(new URL('../../data/track-map/annotations.json',import.meta.url),'utf8'));
assert.deepEqual(extraction.page,{width:7344,height:11540.6,rotation:0});
assert.equal(extraction.operators.c,47195);assert.equal(extraction.operators.l,21181);
assert.equal(extraction.paths.length,14288);assert.equal(extraction.operators.Do??0,0,'Form XObjects require a recursive extractor');
for(const [id,path] of Object.entries(annotations.sourcePaths))assert.deepEqual(path,extraction.paths[Number(id)],`source path ${id} differs`);
console.log(`Verified ${Object.keys(annotations.sourcePaths).length} selected source paths against native extraction; page, rotation and operator counts match.`);
