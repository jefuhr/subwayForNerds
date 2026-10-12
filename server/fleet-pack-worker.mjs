import { parentPort, workerData } from 'node:worker_threads';
import { DatabaseSync } from 'node:sqlite';
import { createWriteStream, statfsSync } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { once } from 'node:events';
import { createGzip } from 'node:zlib';
import { dirname } from 'node:path';
import { readFleetCars } from './fleet-store.mjs';

let source;
let gzip, writing;
const reserve = workerData.reserveBytes ?? 2 * 1024 ** 3;
const maximumArtifactBytes = workerData.maximumArtifactBytes ?? 6 * 1024 ** 3;
let checks = 0, records = 0, uncompressedByteLength = 0, archiveByteLength = 0;
function space(required = 1024 * 1024) {
	const disk = statfsSync(dirname(workerData.destination));
	const sequence = workerData.availableBytesForTests;
	const available = sequence ? sequence[Math.min(checks++, sequence.length - 1)] : disk.bavail * disk.bsize;
	if (available < reserve + required) {
		const error = new Error(`Insufficient disk space for offline fleet pack: ${available} bytes available, ${reserve + required} required including reserve`);
		error.code = 'ENOSPC'; throw error;
	}
}
function currentConsist(car, generatedAt) {
	const last = car.last;
	return last?.consistId && last.timestamp >= generatedAt - 90 && last.timestamp <= generatedAt + 60 ? last.consistId : undefined;
}
try {
	source = new DatabaseSync(workerData.source, { readOnly: true });
	source.exec('PRAGMA busy_timeout=3000; PRAGMA temp_store=MEMORY; BEGIN');
	const version = source.prepare('SELECT MAX(version) AS version FROM migrations').get()?.version;
	if (version !== 1) throw new Error('Unsupported fleet source schema');
	space();
	const { selection } = workerData;
	const generatedAt = workerData.generatedAt ?? Math.floor(Date.now() / 1000);
	const historyStart = generatedAt - selection.historyDays * 86400;
	const historyEnd = Math.max(generatedAt, Number(source.prepare('SELECT MAX(timestamp) AS timestamp FROM events').get()?.timestamp || 0));
	const observedAt = JSON.parse(source.prepare("SELECT data FROM meta WHERE key='observedAt'").get()?.data || 'null');
	const cars = readFleetCars(source, generatedAt).map(car => ({ ...car, reporting: false }));
	const matches = car =>
		(!selection.equipment.length || selection.equipment.includes(car.equipment)) &&
		(!selection.yards.length || selection.yards.includes(car.estimatedYard?.name || 'unknown'));
	const selected = new Set(cars.filter(matches).map(car => car.id));
	const matchedCars = selected.size;
	if (!matchedCars) throw new Error('No cars match this fleet pack selection');
	// Link documented fixed sets and formations that are current at publication.
	// Never traverse every historical consist: that can join unrelated trains.
	let changed;
	do {
		changed = false;
		const fixed = new Set(cars.filter(car => selected.has(car.id)).map(car => car.fixedSet).filter(Boolean));
		const observed = new Set(cars.filter(car => selected.has(car.id)).map(car => currentConsist(car, generatedAt)).filter(Boolean));
		for (const car of cars) if (!selected.has(car.id) &&
			((car.fixedSet && fixed.has(car.fixedSet)) || (currentConsist(car, generatedAt) && observed.has(currentConsist(car, generatedAt))))) {
			selected.add(car.id); changed = true;
		}
	} while (changed);
	source.exec('CREATE TEMP TABLE selected(id TEXT PRIMARY KEY)');
	const insertSelected = source.prepare('INSERT INTO selected VALUES(?)');
	for (const id of [...selected].sort()) insertSelected.run(id);
	const counts = { cars: selected.size, consists: 0, events: 0, assertions: 0, eventCars: 0,
		matchedCars, linkedCars: selected.size - matchedCars };
	const digest = createHash('sha256');
	gzip = createGzip({ level: 6 });
	const hashing = new Transform({ transform(chunk, _encoding, done) {
		try {
			archiveByteLength += chunk.length;
			if (archiveByteLength > maximumArtifactBytes) throw new Error('Offline fleet pack exceeds the safe server size limit');
			space(); digest.update(chunk); done(null, chunk);
		} catch (error) { done(error); }
	} });
	writing = pipeline(gzip, hashing, createWriteStream(workerData.destination, { flags: 'wx' }));
	// A source read can fail before the pipeline is awaited. Keep that rejection
	// observed, then destroy the stream and await it in the catch path.
	writing.catch(() => {});
	async function line(value) {
		const bytes = Buffer.from(JSON.stringify(value) + '\n');
		if (bytes.length > 1_048_576) throw new Error('Offline fleet pack record exceeds the supported size limit');
		uncompressedByteLength += bytes.length;
		if (uncompressedByteLength > 64 * 1024 ** 3) throw new Error('Offline fleet pack expands beyond the supported size limit');
		if (++records % 256 === 0) space();
		if (!gzip.write(bytes)) await once(gzip, 'drain');
	}
	await line(['header', 2, generatedAt, historyStart, historyEnd, selection]);
	for (const car of cars) if (selected.has(car.id)) await line(['car', car.id, JSON.stringify(car)]);
	for (const row of source.prepare('SELECT a.id,a.car_id,a.data FROM assertions a JOIN selected s ON s.id=a.car_id ORDER BY a.id').iterate()) {
		await line(['assertion', row.id, row.car_id, row.data]); counts.assertions++;
	}
	const usedConsists = new Set();
	// The timestamp index contains rowids, so finding the earliest recent row
	// avoids fetching every recent event through a random table lookup. Events
	// can arrive out of timestamp order; use MIN(rowid), not the first timestamp.
	const firstRecentRow = source.prepare('SELECT MIN(rowid) AS rowid FROM events INDEXED BY event_time WHERE timestamp>=?').get(historyStart)?.rowid;
	const query = source.prepare(`SELECT id,timestamp,data FROM events NOT INDEXED
		WHERE rowid>=? AND timestamp>=? ORDER BY rowid`);
	const legacyMembers = source.prepare('SELECT car_id FROM event_cars WHERE event_id=?');
	for (const row of firstRecentRow == null ? [] : query.iterate(firstRecentRow, historyStart)) {
		let event;
		try { event = JSON.parse(row.data); } catch { event = null; }
		// Live observations store the same car IDs in the payload and event_cars.
		// Reading them here avoids an indexed join for every recent event.
		const cars = Array.isArray(event?.cars) && event.cars.every(id => typeof id === 'string')
			? event.cars : legacyMembers.all(row.id).map(member => member.car_id);
		const members = [...new Set(cars.filter(id => selected.has(id)))].sort();
		if (!members.length) continue;
		if (!event) throw new Error('Invalid selected fleet event payload');
		await line(['event', row.id, row.timestamp, row.data, members]);
		counts.events++; counts.eventCars += members.length;
		if (typeof event.consistId === 'string') usedConsists.add(event.consistId);
		if (usedConsists.size > 250_000) throw new Error('Offline fleet pack has too many historical formations');
	}
	for (const car of cars) if (selected.has(car.id)) {
		const consist = currentConsist(car, generatedAt);
		if (consist) usedConsists.add(consist);
	}
	for (const row of source.prepare('SELECT id,data FROM consists ORDER BY id').iterate()) if (usedConsists.has(row.id)) {
		await line(['consist', row.id, row.data]); counts.consists++;
	}
	for (const row of source.prepare("SELECT key,data FROM meta WHERE key IN ('roster','supplement','yardRules','observedAt') ORDER BY key").iterate()) {
		await line(['meta', row.key, row.data]);
	}
	await line(['end', counts]);
	gzip.end();
	await writing;
	source.exec('COMMIT'); source.close(); source = undefined;
	const actual = (await stat(workerData.destination)).size;
	if (archiveByteLength !== actual) throw new Error('Pack archive length mismatch');
	parentPort.postMessage({ schemaVersion: 2, format: 'fleet-jsonl-v2', compression: 'gzip', generatedAt, historyStart, historyEnd,
		...(typeof observedAt === 'number' && Number.isFinite(observedAt) ? { observedAt } : {}), selection, counts,
		archiveByteLength, archiveSha256: digest.digest('hex'), uncompressedByteLength,
		estimatedSavedByteLength: Math.ceil(uncompressedByteLength * 2.5 + 4 * 1024 ** 2) });
} catch (error) {
	gzip?.destroy(error);
	await writing?.catch(() => {});
	parentPort.postMessage({ error: String(error), code: error.code });
} finally {
	source?.close(); parentPort.close();
}
