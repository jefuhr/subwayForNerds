import { parentPort } from 'node:worker_threads';
import { unzipSync, strFromU8 } from 'fflate';
import { parse } from 'csv-parse/sync';
import { parse as streamCsv } from 'csv-parse';
import { Readable } from 'node:stream';

// ZIP inflation and schedule parsing run off the arrival server's event loop.
try {
  const feeds = [];
  // Parse the large archives sequentially so refreshes fit small production hosts.
  for (const name of ['gtfs_subway', 'gtfs_supplemented']) {
    const response = await fetch(`https://rrgtfsfeeds.s3.amazonaws.com/${name}.zip`, { signal: AbortSignal.timeout(60000) });
    if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
    const zip = unzipSync(new Uint8Array(await response.arrayBuffer()), { filter: f => ['stops.txt', 'trips.txt', 'routes.txt', 'stop_times.txt'].includes(f.name) });
    const table = name => zip[name] ? parse(strFromU8(zip[name]), { columns: true, skip_empty_lines: true, bom: true }) : [];
    const representative = new Map(), patterns = new Map();
    for (const t of table('trips.txt')) {
      const key = t.shape_id + '|' + t.trip_headsign;
      if (!t.shape_id || patterns.has(key)) continue;
      const pattern = { route: t.route_id, shape: t.shape_id, headsign: t.trip_headsign, stops: [], source: name };
      patterns.set(key, pattern); representative.set(t.trip_id, pattern);
    }
    if (zip['stop_times.txt']) {
      const bytes = zip['stop_times.txt'];
      function* chunks() {
        for (let offset = 0; offset < bytes.length; offset += 65536) yield bytes.subarray(offset, offset + 65536);
      }
      // A single giant CSV chunk queues the entire table before the consumer can
      // drain it. Bound chunks as well as the retained representative patterns.
      const parser = Readable.from(chunks()).pipe(streamCsv({ columns: true, skip_empty_lines: true, bom: true }));
      for await (const row of parser) {
        const pattern = representative.get(row.trip_id);
        if (pattern) pattern.stops.push({ id: row.stop_id, sequence: Number(row.stop_sequence) });
      }
    }
    for (const pattern of patterns.values()) pattern.stops = pattern.stops.sort((a, b) => a.sequence - b.sequence).map(s => s.id);
    feeds.push({ name, stops: table('stops.txt'), routes: table('routes.txt'), patterns: [...patterns.values()] });
  }
  parentPort.postMessage({ timestamp: Math.floor(Date.now() / 1000), feeds });
} catch (error) { parentPort.postMessage({ error: String(error) }); }
