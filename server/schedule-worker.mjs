import { parentPort, workerData } from 'node:worker_threads';
import { readFile, mkdir, writeFile, rename } from 'node:fs/promises';
import { dirname } from 'node:path';
import { unzipSync, strFromU8 } from 'fflate';
import { parse } from 'csv-parse/sync';
import { parse as streamCsv } from 'csv-parse';
import { Readable } from 'node:stream';

// ZIP inflation and schedule parsing run off the arrival server's event loop.
try {
  if (workerData?.restore) {
    const cached = JSON.parse(await readFile(workerData.restore, 'utf8'));
    const valid = cached.version === 2 && Number.isFinite(cached.timestamp) && Array.isArray(cached.feeds) && cached.feeds.length === 2 && cached.feeds.every(f =>
      Array.isArray(f.calendar) && Array.isArray(f.exceptions) && Array.isArray(f.patterns) && f.patterns.every(p => Array.isArray(p.stops)) &&
      Array.isArray(f.trips) && f.trips.every(t => Array.isArray(t.times) && f.patterns[t.pattern]));
    parentPort.postMessage(valid ? cached : { error: 'Schedule cache requires rebuilding' });
  } else {
  const feeds = [];
  // Parse the large archives sequentially so refreshes fit small production hosts.
  for (const name of ['gtfs_subway', 'gtfs_supplemented']) {
    const response = await fetch(`https://rrgtfsfeeds.s3.amazonaws.com/${name}.zip`, { signal: AbortSignal.timeout(60000) });
    if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
    const zip = unzipSync(new Uint8Array(await response.arrayBuffer()), { filter: f => ['stops.txt', 'trips.txt', 'routes.txt', 'stop_times.txt', 'calendar.txt', 'calendar_dates.txt', 'feed_info.txt'].includes(f.name) });
    const table = name => zip[name] ? parse(strFromU8(zip[name]), { columns: true, skip_empty_lines: true, bom: true }) : [];
    const tripRows = table('trips.txt');
    const rows = new Map(tripRows.map(t => [t.trip_id, []]));
    const time = value => value && /^\d+:\d{2}:\d{2}$/.test(value) ? value.split(':').reduce((n, v) => n * 60 + Number(v), 0) : null;
    if (zip['stop_times.txt']) {
      const bytes = zip['stop_times.txt'];
      function* chunks() {
        for (let offset = 0; offset < bytes.length; offset += 65536) yield bytes.subarray(offset, offset + 65536);
      }
      // A single giant CSV chunk queues the entire table before the consumer can
      // drain it. Bound chunks as well as the retained representative patterns.
      const parser = Readable.from(chunks()).pipe(streamCsv({ columns: true, skip_empty_lines: true, bom: true }));
      for await (const row of parser) {
        const trip = rows.get(row.trip_id);
        if (trip) trip.push([Number(row.stop_sequence), row.stop_id, time(row.arrival_time) ?? time(row.departure_time)]);
      }
    }
    const patterns = [], patternIds = new Map(), trips = [];
    for (const t of tripRows) {
      const calls = rows.get(t.trip_id).sort((a,b) => a[0] - b[0]);
      rows.delete(t.trip_id);
      if (!calls.length) continue;
      const stops = calls.map(s => s[1]);
      const key = JSON.stringify([t.route_id, t.shape_id, t.trip_headsign, t.direction_id, stops]);
      let pattern = patternIds.get(key);
      if (pattern == null) {
        pattern = patterns.length; patternIds.set(key, pattern);
        patterns.push({ route: t.route_id, shape: t.shape_id, headsign: t.trip_headsign, direction: t.direction_id === '0' ? 0 : t.direction_id === '1' ? 1 : undefined, stops, source: name });
      }
      trips.push({ id: t.trip_id, service: t.service_id, pattern, start: calls[0][2], times: calls.map(s => s[2]) });
    }
    feeds.push({ name, stops: table('stops.txt'), routes: table('routes.txt'), patterns, trips,
      calendar: table('calendar.txt'), exceptions: table('calendar_dates.txt'), info: table('feed_info.txt')[0] });
  }
  const result = { version: 2, timestamp: Math.floor(Date.now() / 1000), feeds };
  if (workerData?.cacheFile) {
    await mkdir(dirname(workerData.cacheFile), { recursive: true });
    await writeFile(workerData.cacheFile + '.tmp', JSON.stringify(result));
    await rename(workerData.cacheFile + '.tmp', workerData.cacheFile);
  }
  parentPort.postMessage(result);
  }
} catch (error) { parentPort.postMessage({ error: String(error) }); }
