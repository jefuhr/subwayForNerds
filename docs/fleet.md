# Fleet data and operations

The fleet browser is a separate, optional read model. It does not participate in
departure requests or delay train-feed startup. It uses `node:sqlite` in a worker
thread; Node 22.13 or newer is required (SQLite is experimental on Node 22).

## Coverage

`data/fleet-roster.base64` is a gzip/base64-encoded snapshot of the complete NYCT
Open Data inventory, including retired records and source duplicates. Its JSON
contains `date` (retrieval date) and `rows` (unmodified source records). Decode it
with Node's `gunzipSync` for inspection. The source is
https://data.ny.gov/resource/kir5-i9xt.json. A daily background import updates it
in the database, not in the repository. Failed/truncated imports preserve the
previous inventory. The monthly inventory is not an operational train census.

The source contains reused numbers, duplicated records, and contradictory class
and lifecycle fields. Namespace, equipment family and number identify distinct
roster records; conflicting records remain separate and are flagged. R160A/B
reports match the source's R160 family. No other class conversion is assumed.
Do not strip retired-number suffixes or merge converted cars without evidence.
Source assertions are retained independently of the display record.

`data/fleet-supplement.json` supplies source-linked SIR, work and museum records,
documented links, and route-based home-yard estimates. Its dates are review dates
unless a note explicitly supplies the historical event date. Initial supplemental
coverage is 75 R211S cars, 28 R156 locomotives and 29 preserved vehicles; it is NOT
a complete work/museum/SIR historical roster. Additional classes require verified
number ranges and provenance, not fabricated rows. Historical museum-condition
notes do not establish a current location. Yard rules are estimates from published
maintenance assignments, not evidence that a car entered a yard. A/C are deliberately
unmapped because multiple facilities make a single route-based estimate ambiguous.
Documented R143 and R188 class-wide yard assignments can supply estimates even for
cars never observed here. Conflicting class/route hints produce unknown, not an
arbitrary choice.

All imported identities are searchable. An explicit lifecycle filter includes
retired/scrapped records. Ambiguous records are not silently discarded. A car
never seen by this server says “Never observed”; history begins with collection,
not the car's entry into service.

## Collection and retention

The existing Helium poller supplies car lists, joined to GTFS by operations ID,
route and freshness. Conflicting simultaneous car claims suppress the entire
affected formation. Reported order does not identify the leading car. A physical
formation's stable ID depends on membership; order is stored in observations.
Documented permanent sets are separate from observed operating consists.

Current reporting requires an unambiguous association in the latest processed
snapshot and timestamps no older than 90 seconds. Startup restores historical
observations but never labels them current until new reports arrive. Feed loss
does not prove inactivity. Location report timestamps are distinct from car/trip
association timestamps. Predictions without vehicle reports say “next reported
stop,” not “at.”

Changes of station/status, route, order or trip generate events. Repeated polls
update the latest report without duplicating unchanged history. Events are shared
between member cars and kept for 30 days; latest reports and source assertions
are retained indefinitely. Detail responses show the latest 200 matching events.
Historical formations remain queryable after their members change assignments.

## Storage, backup and recovery

The database is `STATE_DIR/fleet.sqlite` with WAL and foreign keys enabled.
Never package it into a release or replace it with the seed. Seed import runs only
when no roster has been imported. Schema version 1 is recorded in `migrations`;
unsupported versions must fail the fleet worker without affecting departure APIs.

Create a consistent backup while the service runs:

```sh
npm run fleet:db -- backup state/fleet.sqlite /absolute/path/fleet-snapshot.sqlite
npm run fleet:db -- check /absolute/path/fleet-snapshot.sqlite
```

The destination must not exist. `VACUUM INTO` includes committed WAL content;
copying only a live `.sqlite` file does not. To restore, stop the subway service
when deployment is explicitly authorized, preserve the existing state directory,
and use the backup command with the snapshot as input and a fresh database path
in a new state directory. Point `STATE_DIR` there and restart. Do not overwrite or
delete the original database/WAL files. Existing JSON feed caches are optional.

`/api/v1/fleet/health` reports database initialization/errors independently of
train-feed health. API failures are isolated to fleet requests. Work queued for
the database is drained on graceful shutdown. Migration and backup tests use
temporary databases, never the production state directory.

## Interfaces

- `GET fleet`: `q`, `view=groups|cars`, `category`, `status=reporting|unreported`,
  `equipment`, `route`, `yard`, `retired=true`, `page`. Pages contain at most 100
  groups, with all member car identities searchable. Unknown categories match none.
- `GET fleet/cars/:id` and `GET fleet/consists/:id`: URL-encoded stable identity,
  provenance, latest reports and 30-day history. Missing identity returns 404.
- `GET trips/transfers?key=…&stopId=…&sequence=…`: unique stop visit, incoming
  arrival (explicit departure fallback), connections in the following 30 minutes,
  raw gaps, and freshness. An ambiguous or removed visit returns an explanation.

These endpoints live under the existing `/subwaysForNerds/api/v1` prefix. None
fetch upstream data on request. The deprecated `Departure.onward` payload remains
for existing clients; the comparison UI and ranking logic are removed.

No deployment is part of this change.

## Native offline snapshots

The iPhone app can download a public, versioned SQLite snapshot. The operational
`fleet.sqlite` and WAL files remain private server state and are never served directly.

- `GET fleet/offline/manifest` returns schema version, snapshot ID, generation time,
  history bounds, record counts, and an origin-relative download URL. `id`, `byteLength`,
  and `sha256` describe the expanded SQLite file; `compression: "gzip"`,
  `compressedByteLength`, and `compressedSha256` describe the transfer file.
- `GET fleet/offline/snapshots/:id.sqlite.gz` streams an immutable `application/gzip`
  file with a compressed-file ETag, Content-Length, and byte-range/If-Range support.
  No `Content-Encoding` is added: the app verifies and expands the archive itself.
  The legacy raw `.sqlite` route remains available for retained raw artifacts.
  Requests before the first successful
  export receive a retryable 503 manifest response.
- A dedicated worker establishes one read-only transaction and exports the full roster,
  provenance, last reports, consists, and retained events, independently of the live
  fleet request worker. Every downloaded car has `reporting: false`.
- Exports run after fleet initialization and hourly thereafter. Files and manifests are
  published atomically under `STATE_DIR/fleet-offline/`. At most two artifacts are
  retained, with 24-hour retention best effort for older files. Space pressure can
  remove the previous generation earlier. The current valid snapshot remains even
  if regeneration fails; downloads already opened remain readable after pruning.
- Exporting and gzip compression use bounded buffers and preserve a 2 GiB disk
  reserve. Preflight budgets live SQLite pages, up to 2 GiB compression headroom,
  and 16 MiB working space beyond that reserve. Space is checked while inserting
  rows and writing compressed chunks. Failure removes staging files and keeps the
  current manifest; history is never shortened to make an export fit.
- Snapshot schema version 1 uses `PRAGMA user_version=1`, with `meta`, `cars`,
  `assertions`, `consists`, `events`, and `event_cars`. `meta.snapshot` records the
  generation time, history bounds, counts, and latest processed observation time.
  This format is versioned independently from the operational schema.

Deploy these additive routes to enable production iPhone downloads. Existing web
clients and transit routes continue to work. No web download interface is added.
`GET fleet/health` includes an additive `offline` object with snapshot availability,
publication time, and the last export error, so an operator can distinguish a failed
export from the initial preparation period.
The September 28 read-only inspection found a roughly 12 GB operational database
and 22 GB free disk. Fixture compression results do not establish production size,
duration, or peak space use. Measure the first full export before enabling downloads
for device acceptance; deployment remains subject to approval.

## Local validation

Run `npm run check` and `npm run test:browser`. The browser suite uses recorded
feeds, a frozen clock, synthetic car assignments, and a temporary fleet database.
No live upstream service is required. Mobile keyboard tests simulate the visual
viewport; they do not replace testing Safari and SwiftKey on an actual iPhone.

`npx tsx scripts/benchmark-fleet.ts` measures localhost departure responses with
the fleet worker idle versus ingesting 100 synthetic ten-car consists every
200 ms (production polls every 10 seconds). It alternates three phases of 800
requests at concurrency eight. A local run on 2026-09-06 measured median p95
5.94 ms idle versus 6.17 ms loaded (+3.9%). This is a development-host regression
check, not a production-device/network latency guarantee.
