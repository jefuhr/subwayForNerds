# Estimated slow zones

Board rows tag a train that is between two stops of an estimated slow zone right now.
Train details list every estimated slow zone left on the remaining route, placed
between the two stops it covers. The tag shows the typical extra time, such as `+42s`.
The web, iOS and Android clients use the same wording: "slow zone" or "major slowdown",
a summary such as "2 estimated slow zones ahead · about +2m 56s typical", and the
Transit Lab attribution under the stopping pattern.

## Source

[Transit Lab's subway slow zones dataset](https://docs.transitlab.nyc/datasets/subway-slow-zones/)
(`https://data.transitlab.nyc/v1/subway_slow_zones.parquet`, CC BY 4.0) is built
nightly from archived MTA realtime feeds. It is an outside estimate: the MTA does not
publish its speed restrictions, and this is not a copy of an official list.

Each row is one episode on one directional segment: two consecutive stops, identified
by GTFS stop IDs with N/S suffixes (`R09S → R60S`). An episode is four or more
consecutive weekdays, with one ordinary day allowed, on which trains took at least 10%
**and** 10 seconds longer than usual. "Usual" is the 10th percentile of the previous
120 weekdays. Run times are weekday 06:00–21:59, departure to departure, so they
include the dwell at the second stop.

| Kind | Meaning | Used |
| --- | --- | --- |
| `slow zone` | Median extra time up to 2 minutes and 150%; likely a speed restriction or nearby work | Yes, labeled "slow zone" |
| `disruption` | Larger: reroutes, skipped stops, shuttles | Yes, labeled "major slowdown" |
| `service change` | Routes using the segment changed, or the segment is new | No |
| `system-wide change` | 15 or more episodes started the same day | No |

Segment endpoints include non-station timing points that also appear in NYCT trip
updates, such as `R60` (60 St tunnel) and `R65` (Montague St tunnel).

## Rules

- **Active:** a `slow zone` or `disruption` whose last slow weekday is within seven days
  of the dataset's latest date (the maximum `end_date`). This reproduces the active
  count on transitlab.nyc. If a segment has more than one active episode, the latest wins.
- **Stale data:** if the latest date is more than 14 days before today (Eastern), no
  zones are shown and `health.slowZones.status` is `degraded`.
- **Ahead:** consecutive stops in the train's remaining predictions, starting at its
  reported position. Skipped stops are bridged. Matching uses the stop pair only, so
  a rerouted train still matches slow track; the route is not compared.
- **Current:** the train must be moving toward the segment's end stop. `IN_TRANSIT_TO`
  and `INCOMING_AT` count, and `STOPPED_AT` never does. NYCT omits the status for many
  moving trains; GTFS-rt's default for a missing status is `IN_TRANSIT_TO`. A missing
  status counts only when the evidence agrees: the position report is not newer than the
  feed (trips still at their terminal carry future placeholder times), the reported stop
  is the first remaining prediction, and its predicted arrival is still ahead. On
  2026-10-16, 29 of about 700 trains reported an explicit moving status and another 57
  met this rule. Board rows keep their "Reported near" wording for these trains. The
  previous stop comes from, in order:
  1. the last different stop the server observed for that trip (kept in memory for
     15 minutes and capped at 10,000 trips; not invented after a restart),
  2. an earlier served stop still present in the trip update,
  3. the matched static schedule pattern.

  Without any of those, a zone is accepted only when exactly one active zone ends at
  that stop and its measured routes include the train's route. Otherwise nothing is shown.
- **Cached boards:** offline or cached boards hide the live tag. Train details omit the
  "now" marker when the trip report is not live.

## Limits

- Segment granularity: the slow section can be anywhere between the two stops.
- Busier platforms can look like a slow zone because dwell time is included.
- Weekday daytime only; nights and weekends are not measured.
- A rarely used segment can carry an episode whose `since` date is long ago, because
  only weekdays with trains on that segment count toward continuity.
- Rider and train-hour impact columns are not used.

## Operations

The server downloads the parquet file every six hours with `If-None-Match` and decodes it
in about 30 ms with the pinned `hyparquet` package. zstd uses Node's built-in
`zlib.zstdDecompressSync`, which requires Node 22.15 or newer. The active list is saved to
`STATE_DIR/slow-zones.json` and restored on startup. A failed or incomplete download
(under 1,000 rows) keeps the last good data and reports the error. `api/v1/health`
includes `slowZones: { status, dataThrough, active, timestamp, fetchedAt, fetchAge, error }`.
Slow zones never change the overall health status.

API fields (additive):

- `Departure.slowZone`: the zone the train is in now. Board rows only.
- `Train.slowZones`: each zone ahead with `toIndex`, the index of its end stop in
  `Train.stops`. The current zone has `current: true` and is listed first.

Tests use `test/fixtures/subway_slow_zones.parquet`, a 2026-10-16 snapshot of the
Transit Lab file, and synthetic rows injected by `test/fixture-service.ts` for the
recorded feeds. Those synthetic rows do not describe real track conditions.

Attribution: data © Transit Lab (transitlab.nyc), CC BY 4.0, built from public MTA data
and not endorsed by the MTA.
