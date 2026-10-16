import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Local development preparation only. Distribution requires the author's written consent.
const root = fileURLToPath(new URL('../', import.meta.url));
const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== '--pdf') {
	console.error('Usage: node scripts/prepare-track-map.mjs --pdf /path/to/NYC_full_trackmap.pdf');
	process.exit(1);
}
const source = await readFile(resolve(args[1]));
const topologyBytes = await readFile(resolve(root, 'data/track-map/nyc-2.6.8-v1.json'));
const topology = JSON.parse(topologyBytes.toString('utf8'));
const digest = createHash('sha256').update(source).digest('hex');
if (digest !== topology.pdfSha256) throw new Error('PDF does not match the reviewed topology. Do not update either independently.');
for (const relative of ['ios/SubwaysForNerds/Resources/TrackMap', 'android/app/src/main/assets/track-map']) {
	const destination = resolve(root, relative);
	await mkdir(destination, { recursive: true });
	await writeFile(resolve(destination, 'NYC_full_trackmap.pdf'), source);
	await writeFile(resolve(destination, 'topology.json'), topologyBytes);
	console.log(`Prepared local map resources: ${relative}`);
}
