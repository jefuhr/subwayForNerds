# Subways for Nerds

A station-first NYC subway console for people who already know the map. Live
departures, stop-relative train positions, reported tracks, stopping patterns,
operations IDs, physical car numbers when reported, future-stop connections, and a persistent fleet browser. Web first, with a future Capacitor
wrapper in mind.

## Run locally

Requires Node.js 22.13 or newer. No API key is needed for the currently configured
public endpoints.

```sh
npm ci
npm run dev
```

Open `http://localhost:5173/subwaysForNerds/`. The API runs on port 8091.
For the production build, including offline installation:

```sh
npm run build
npm start
```

Open `http://localhost:8091/subwaysForNerds/`. Initial station boards are available
immediately; upstream feeds populate them independently. Use HTTPS when exposing
the app beyond localhost so geolocation and service workers work.

## How the board works

- A fresh visit with saved favorites requests one location fix and opens the
  closest favorite; if location is unavailable, the last station is restored
  (Union Square is the initial fallback). The station title opens search; stars
  save favorites. A nearby button can request location again and sorts stations
  on-device by straight-line distance.
- A complex includes its constituent stations. Direction, constituent station and
  reported/scheduled track define the groups. A group is a feed-based boarding
  area, not a guarantee of shared platform access. Unknown tracks stay unknown.
- Trains from different routes are interleaved by predicted time. Five rows per
  group are shown initially; each group can expand. Route and direction filters
  persist across visits. Tap a train for its full remaining stop sequence and raw
  decoded NYCT fields.
- Tap a future stop inside train details to compare connecting departures against
  that train's predicted arrival. Raw gaps include no walking buffer or guaranteed
  platform access. Stale, skipped, canceled and unassigned predictions are excluded.
- Open Fleet for grouped consists or individual cars, last reports, sourced home-yard
  estimates and 30 days of collected movement history. See [fleet data and operations](docs/fleet.md)
  for coverage, identity rules, backup/restore and API details.
- Station info includes constituent station accessibility, entrance coordinates,
  equipment status, upcoming/current outages and published travel alternatives.
- Ten themes: the original Subway Console plus NYC Ferry, Night, Hello Kitty,
  Cinnamoroll, Pompompurin, Kuromi, Windows XP, Hacker and Burger King.

## Data boundaries

The server polls all eight subway/SIR groups every 15 seconds and alerts and
equipment feeds every 60 seconds. It refreshes station/entrance metadata daily and
regular/supplemented GTFS hourly. Pollers use independent timeouts and backoff;
changed feeds are decoded once, indexed, and published as station snapshots.
Requests for station boards never trigger an upstream fetch. ZIP parsing runs in
a worker thread. The `state/` directory retains last successful responses.

Preserved feed fields distinguish absent assignment/status from explicit false or
zero. Vehicle joins use feed, service date, trip ID and start time. Entity numbers
are not train identities. Exact signal blocks are not available from these sources.

A separate server poller requests `https://helium-prod.mylirr.org/v1/subway/trips`
every 10 seconds, with independent timeout/backoff. Helium's `tripId` matches the
NYCT extension's `train_id`, not the GTFS `trip_id`. Matching routes and reports
within five minutes of each other can attach `consistCars` numbers and equipment
types to departures and train details. Stale routes, ambiguous IDs, unassigned
trains, and invalid car lists are omitted. Car data expires five minutes after
its report or fetch time; failed requests do not interrupt departure predictions.
The fleet database retains last observations across restarts, but only new reports
can establish current assignments. Cached offline boards hide live car lists.
Reported order does not establish which end of the train is leading.

Scheduled and reported actual track fields are separate. Some feed groups populate
`actual_track` at future stops; this is not evidence of the train's current
physical track. Missing vehicle status is shown as “reported near”, and predictions
alone as “next reported stop”. Old position reports carry their age rather than an
invented movement status.

Corridor names come from MTA station metadata. Local/express is inferred only for
the explicitly supported Brighton, Lexington Avenue and Broadway–7 Avenue
corridors, using remaining stops and curated GTFS-verified stop sequences. Other corridors
show their official line name without guessing a local/express designation.
Matching static GTFS shapes are available as a separately labeled comparison in
train detail. Static schedules never add arrivals or override realtime predictions.
No date/timetable browser is included.

A source becomes stale after 90 seconds and expired after five minutes. The UI
conservatively replaces countdowns with last-known clock times at the stale
threshold, and always does so for offline cached boards. Individual source ages
remain visible. An empty board is not a claim that service is suspended. Explicit
skips/cancellations are marked; disappearance alone is not labeled canceled.

Station alerts are filtered by active periods and affected stops/routes. The raw
Mercury alert is accessible for additional details. Equipment is joined by official
complex/GTFS identifiers and outages by equipment number. A missing feed never
means “all elevators working”.

## HTTP interface

All app endpoints live under `/subwaysForNerds/api/v1/`:

| Endpoint | Result |
| --- | --- |
| `stations` | Station complexes and constituent stations |
| `stations/:id/board` | Indexed departures, onward predictions, relevant alerts and source ages |
| `stations/:id/context` | Entrances, equipment, outages and source states |
| `trips?key=…` | Normalized train and original decoded trip/position entities |
| `health` | Per-feed availability and catalog count |

JSON responses support ETags and conditional requests. `/healthz` checks process
liveness; inspect `api/v1/health` for upstream health. Times are Unix seconds;
the UI formats them in `America/New_York`. Shared contracts are in `shared/types.ts`.

## Deployment

The juliet.nyc host already runs `subways-for-nerds.service` from
`/opt/subways-for-nerds`, behind its existing nginx prefix. The local
`~/deploy-sfn.sh` helper builds the frontend locally, backs up the deployed app,
ships committed `main` source plus `dist/`, restarts only the subway service, and
checks the public endpoints. Commit the intended release before using that helper;
it archives committed source, while building the frontend from the checkout.

For a new container-based host instead:

```sh
docker compose up --build -d
```

The container runs as an unprivileged user, listens on loopback port 8091 through
Compose, and persists feed data in a named volume. Add the locations in
`deploy/nginx.conf` to juliet.nyc's existing HTTPS server block. The proxy preserves
the entire prefix. No root-level `/api`, `/assets`, `/sw.js`, or ferry routes change.

`APP_BASE` defaults to `/subwaysForNerds/` and must match at build time and runtime.
The service worker, manifest, navigation and API remain scoped to it. `HOST`,
`PORT` and `STATE_DIR` configure the server. `FIXTURE_DIR` is a development-only
option for replaying the original investigation's decoded JSON tree; replay dates
are preserved so old captures remain visibly stale.

The systemd and container approaches are alternatives. Do not start a second
server on port 8091 alongside the existing systemd deployment.

## Verification

```sh
npm run check
npx playwright install --with-deps chromium
npm run test:browser
node scripts/capture.mjs
node scripts/benchmark.mjs
```

The browser suite starts an isolated server with checked-in recorded feed bytes
and fixes the browser clock to their capture time. It covers desktop/mobile layout,
search, favorites, themes, filters, train details, denied geolocation and offline
service-worker recovery. The API tests cover decoding all nine protobuf feeds,
missing extension values, identity joins, track differences, partial failures,
ETags, stale feeds and direct-train comparisons. Browser installation commands
require a Playwright-supported OS or an equivalent local browser runtime.

The benchmark uses the running production server and records results under
`artifacts/`. Targets: API p95 below 100ms at 50 concurrent clients, cold usable
board below 1.5s on the documented mobile profile, and cached board restoration
below 200ms. Actual results and platform limitations belong in `docs/validation.md`.

## Sources and reuse

- [MTA developer resources](https://www.mta.info/developers), including the linked
  NYCT and Mercury protobuf definitions, regular and supplemented GTFS.
- [MTA subway stations](https://data.ny.gov/Transportation/MTA-Subway-Stations/39hk-dx4f)
  and [entrances](https://data.ny.gov/Transportation/MTA-Subway-Entrances-and-Exits-2024/i9wp-a4ja).
- [MTA station accessibility and equipment guidance](https://www.mta.info/developers/display-elevators-NYCT).
- The user's `~/leet/mta_realtime_investigation` supplied immutable binary fixtures.
- Theme palettes and local Lato/Flame font assets were adapted from the user's
  `~/DiD_Open` mobile branch. The interface and transit service are new.

No accounts or analytics are included. Location stays on-device. Browser storage
holds preferences, a station catalog, and up to eight recent station snapshots.
Future native shells can reuse the API/UI and replace `src/platform.ts` adapters
for native storage and geolocation.
