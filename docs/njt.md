# NJ TRANSIT Light Rail

The server connects Hudson–Bergen Light Rail, Newark Light Rail, and River LINE
through NJ TRANSIT's official bus G2 GTFS-RT product. Static GTFS from that same
product supplies route, trip, stop, and destination identities. Public rail GTFS
and rail GTFS-RT use different identities and must not be mixed with this source.

## Configuration

Set `NJT_USERNAME` and `NJT_PASSWORD` in the server environment or the ignored
repository-root `.env`. Normal server startup loads that local file. These values
must never use `VITE_` prefixes or appear in native configuration, app exports,
URLs, browser storage, or logs. `NJT_ENABLED=0` disables the integration and keeps
all 62 stations available as an external departure directory.

Run `npm run njt:check` to authenticate, read the product's static identities,
fetch trip updates and positions separately, exercise station boards, and verify
that the latest positions restore from disk. The JSON report and isolated cache
are written under ignored `artifacts/`. An empty successful feed is not proof of
live prediction coverage or lack of service.

The production API server needs these credentials too. Installing the iOS client
alone cannot enable a server-side feed. The app and widgets consume the existing
station-board API; credentials stay on the server.

## Predictions and Positions

Only explicit realtime arrival or departure timestamps populate arrival boards.
`NO_DATA`, skipped stops, canceled trips, and rows without an actual prediction
are excluded. Static scheduled times never fill a gap in realtime data. Live
predictions remain usable when vehicle positions are unavailable, and fresh GPS
positions do not establish that arrivals are live.

NJT predictions and GPS observations use a 60-second live threshold. Older
predictions become last estimates and positions become last known. Positions
older than five minutes are hidden from current-location displays. The source
observation time, rather than the last fetch or app restart, determines age.
Existing MTA freshness rules retain their 90-second threshold.

The server polls trip updates and positions independently every 30 seconds,
refreshes static identity data daily, reuses authentication tokens, and applies
bounded backoff on errors. Latest actual vehicle observations persist atomically
under `STATE_DIR` (or `state/`). Each provider/system/vehicle has one retained
observation, with its trip identity and original source timestamp. Invalid
coordinates, regressing timestamps, and ambiguous trip joins are rejected.
No movement history or schedule-based position interpolation is generated.

The station board can show reported vehicles for its light rail system even when
there are no station predictions. Coordinates describe actual GPS observations;
stop names appear only when reported stop identities can be resolved. A recent
GPS observation does not establish that a vehicle is carrying passengers or
still operating its assigned trip.

## Coverage and Diagnostics

`/api/v1/health` reports NJT independently from MTA and PATH. Prediction access,
position access, static identity readiness, and position-cache errors must be
assessed separately. Existing station IDs remain stable for favorites.

The initial authenticated check verified two River LINE vehicle positions and
all three systems in the bus G2 static archive. Newark trip updates contained
`NO_DATA`; HBLR observations and River LINE predictions were absent. Actual
upstream coverage can change by service period. The implementation handles all
three systems, while the UI reports the data actually received and preserves
links to official departures, schedules, and service alerts.
