# Trip-specific service changes

Departures, trip details, future stops and transfer departures expose operational
changes. Compact badges distinguish scheduled variations from planned work,
unplanned disruptions and reports whose cause is unknown. Track changes ahead
include a location so they cannot be mistaken for the boarding station's track.

## What “normal” means

The reference is regular weekday daytime service: regular GTFS trips originating
between 10:00 and 16:00, within the applicable timetable's weekday calendars.
Routes without midday service fall back to their 06:00–22:00 weekday trips.
Direction and destination branches remain separate. Conflicting daytime
alternatives suppress automatic comparisons rather than selecting a convenient
baseline. Overnight and weekend variations remain visible but are not presented
as unexpected disruptions.

Regular and supplemented schedules are independently matched to the live trip's
service date and normalized MTA trip identity. An origin-time/direction fallback
is accepted only when its pattern and timing are unambiguous. Calendar exceptions,
times beyond 24:00 and GTFS's local-noon-minus-twelve-hours DST semantics are
preserved. Static times never replace live countdowns.

The schedule importer retains all trip stopping sequences, deduplicates patterns,
and retains timings and service calendars. Import, JSON cache parsing and cache
serialization run in a worker. Cache version 2 replaces the old representative-
shape cache automatically; an incompatible cache is ignored and rebuilt. Startup
does not wait for schedule restoration before loading departure feeds.

## Evidence and limitations

- NYCT actual/scheduled track differences are reported explicitly. Consecutive
  observations can also reveal reassignment even when actual and scheduled track
  now agree. History is in memory, scoped to full trip identity and unambiguous
  stop occurrence; it expires after 15 minutes without observation and is capped
  at 10,000 trips. Restart does not invent prior assignments.
- Bounded stop-pattern differences use two shared, ordered anchors. Missing
  beginning/end predictions are not evidence of cancellation or a shortened trip.
  Shorter-route labels require a complete matched scheduled pattern.
- Alerts preserve Mercury category, selector priority, direction, service date,
  affected-station selectors and human-readable active periods. Each selector's
  constraints stay together. Active periods are checked at predicted passage;
  an omitted station can use schedule-weighted interpolation between two live
  anchors. That remains an advisory, not a promise about the train.
- Route-level notices are explicitly advisories. A source's planned-work evidence
  or explicit disruption category supplies the classification; absence of a
  planned-work alert never proves an unplanned incident. Track mismatches alone
  have unknown cause, including at terminals.
- Reported changes use 90-second freshness; schedule comparisons require a
  successful schedule snapshot no older than two hours. Failed sources and
  offline cached badges are labeled last-known. Missing/expired schedule data
  disables schedule-derived comparisons while direct reports still work.
- Future stop tracks describe those stops, not the train's current physical
  location. No signal-block, platform-access or track-direction map is invented.

MTA's supplemented schedule includes most, not all, changes in its supported
seven-day window. Long-term changes can be incorporated into regular GTFS and
therefore become part of the reference. No dataset can establish every departure's
exact deviation or cause; unknown cases deliberately remain unknown.

## API and performance

Existing endpoints retain their fields. Optional `changes` arrays on `Train`,
`Departure` and `StopPrediction` carry kind, classification, label, affected stops,
snapshot-local stop indices, evidence timestamps and alert references. Full
`description` text is provided on the train's changes; board and stop entries are
compact summaries. Clients must not persist stop indices across trip snapshots.

Board summaries only include changes at boarding or ahead, ordered with current
boarding/track changes first. The UI shows two badges and a remaining count;
opening train details exposes every explanation. Transfer departures reuse board
summaries. No new endpoint, fleet migration or database is required.

Change analysis is cached for unchanged normalized trains until source updates,
stop-passage boundaries or freshness changes. Departure requests still serve
precomputed, ETag-capable snapshots without upstream requests.

Validation commands:

```sh
npm run check
npm run test:browser
npx tsx scripts/benchmark-changes.ts
```

The benchmark reads `state/*.json`, fetches public schedules, and uses an ephemeral
loopback server. It does not deploy or modify the fleet database.

Local validation on September 7, 2026: 502 replayed trains; 50 concurrent clients;
1,000 idle requests and 14,000 throughout a second schedule import and its
publication, with board refreshes every second. Idle p95 was 99.6 ms; import-load
p95 was 66.5 ms (maximum 591.5 ms). The first full schedule analysis took 279 ms;
maximum refresh during the loaded run was 256 ms, including new-schedule analysis.
The schedule import took 12.5 seconds independently of departure requests.
RSS after the loaded run was about 907 MB. These are local replay
measurements, not production or phone-network performance guarantees.

Sources: [MTA developer resources](https://www.mta.info/developers),
[NYCT realtime reference](https://new.mta.info/document/134521),
[GTFS schedule reference](https://gtfs.org/documentation/schedule/reference/).
