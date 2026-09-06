import { parentPort } from 'node:worker_threads';
import { unzipSync, strFromU8 } from 'fflate';
import { parse } from 'csv-parse/sync';

// ZIP inflation and schedule parsing run off the arrival server's event loop.
try {
  const feeds = await Promise.all(['gtfs_subway', 'gtfs_supplemented'].map(async name => {
    const response = await fetch(`https://rrgtfsfeeds.s3.amazonaws.com/${name}.zip`, { signal: AbortSignal.timeout(60000) });
    if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
    const zip = unzipSync(new Uint8Array(await response.arrayBuffer()), { filter: f => ['stops.txt', 'trips.txt', 'routes.txt'].includes(f.name) });
    const table = name => zip[name] ? parse(strFromU8(zip[name]), { columns: true, skip_empty_lines: true, bom: true }) : [];
    const trips = table('trips.txt').map(t => ({ id: t.trip_id, route: t.route_id, headsign: t.trip_headsign, service: t.service_id, shape: t.shape_id }));
    return { name, stops: table('stops.txt'), routes: table('routes.txt'), trips };
  }));
  parentPort.postMessage({ timestamp: Math.floor(Date.now() / 1000), feeds });
} catch (error) { parentPort.postMessage({ error: String(error) }); }
