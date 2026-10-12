# Transit API access research

Checked October 11, 2026. This records published documentation and the remaining
verification work; it does not establish a license or add an NJ TRANSIT integration.

## Helium

The app's equipment poller uses `https://helium-prod.mylirr.org/v1/subway/trips`.
No Helium-specific published terms were found on the official developer pages.
The [MTA developer terms](https://www.mta.info/developers/terms-and-conditions)
are the relevant published reference, but their applicability to this undocumented
endpoint has not been confirmed with MTA.

Those terms require serving data through a non-MTA server, prohibit claims of
endorsement or guaranteed accuracy/completeness/timeliness, require a notice
when data displayed as real-time lags by more than one minute, and restrict
altering the feed (subsetting is allowed). Branding has separate licensing
requirements, and access can be suspended. See the
[official developer page](https://www.mta.info/developers) for listed feeds and
current terms. The existing server proxy fits the delivery requirement; the
app's 90-second stale threshold deserves a separate review against the
one-minute notice requirement. No compliance conclusion is implied here.

## NJ TRANSIT light rail

The [BUSDATA API manual](https://developer.njtransit.com/registration/files/NJTRANSIT_BUSDATA_V1.pdf)
explicitly documents light rail schedules. Its mode values include `NLR`
(Newark Light Rail), `HBLR` (Hudson-Bergen Light Rail), and `RL` (River LINE),
alongside `BUS` and `ALL`. Relevant methods include `getLocations`,
`getBusRoutes`, `getBusLocationsData`, `getVehicleLocations`, `getStops`,
`getBusDV`, and `getTripStops`. The presence of vehicle/departure methods does
not establish that live light rail predictions are populated for this account.

The documented production base is `https://pcsdata.njtransit.com/api/BUSDV2/`
and test base is `https://testpcsdata.njtransit.com/api/BUSDV2/`.
`authenticateUser` accepts the developer username and password by POST multipart
form and returns a `UserToken`, normally valid for 24 hours. Requests then use
that token. Keep credentials and tokens on the server and out of app exports,
source control, browser storage, URLs, and logs.

The public [rail GTFS archive](https://www.njtransit.com/rail_data.zip) was checked
and includes all three light rail systems as route type 0: route IDs `4` (HBLR),
`13` (NLR), and `17` (RVLN). This is a verified schedule source, not live arrivals.
The bus archive contains bus routes. The separate
[RailData manual](https://developer.njtransit.com/registration/files/NJTRANSIT_RailData_API_V2_1.pdf)
and [Rail GTFS-RT manual](https://developer.njtransit.com/registration/files/NJTRANSIT_Rail_GTFSRT_V1.pdf)
do not by themselves establish light rail realtime coverage.

The [NJ TRANSIT terms](https://developer.njtransit.com/terms/) require a server
proxy and a delay notice beyond 60 seconds, prohibit misleading endorsement and
feed alteration, cap requests at 100,000 per day without written consent, and
describe the public service as unsuitable for reliance for commercial purposes.
Product-specific documentation may impose tighter limits.

## Repeatable BUSDATA coverage probe

Run `npm run --silent njt:probe` from the repository root. The command reads
`NJT_USERNAME` and `NJT_PASSWORD` from the server environment or the ignored
`.env` file. Do not use `VITE_` prefixes or put credentials on the command line.
Credentials were configured locally and authenticated successfully on October
11, 2026. Keep the `.env` file and its editor swap files out of source control.

The probe makes one authentication request followed by separate departure and
vehicle requests for HBLR, NLR, and River LINE, with no automatic retries.
It samples Hoboken, Newark Penn, and Trenton, with a one-mile vehicle search
around each station. This is a bounded initial sample, not system-wide coverage.
Authentication is performed once per invocation; avoid repeated invocations
when investigating account limits.

To preserve a report:

```sh
mkdir -p artifacts
npm run --silent njt:probe > artifacts/njt-coverage.json
```

Exit code 1 means missing credentials, authentication failure, or a failed
sample. Exit code 0 only means all six sample responses were structurally
readable, not that realtime coverage was established. Reports contain counts,
allowlisted field names, request timestamps, and HTTP statuses. They omit
credentials, tokens, arbitrary response text, and vehicle observations.
`fetchedAt` is a request timestamp, never a vehicle observation timestamp.

A nonempty response is `unverified`, an empty list is `empty`, and a malformed
or inaccessible response is `failed`. Neither empty responses nor failures
prove that a system is unsupported. Scheduled departure values and vehicle IDs
alone cannot establish realtime predictions or recent vehicle observations.
The probe deliberately never sets `integrationReady` to true.

## Authenticated Coverage Check: October 11, 2026

Production requests were checked at approximately 11:55-11:57 PM Eastern.
BUSDATA, rail GTFS-RT, and bus G2 all authenticated successfully. This is a
late-night snapshot; absence of data does not establish lack of daytime coverage.

| Product | Observed light rail evidence | Interpretation |
| --- | --- | --- |
| BUSDATA | One departure at Hoboken and one at Newark Penn; no Trenton departures; all three one-mile vehicle searches empty | Access confirmed; realtime departure semantics remain unverified |
| Rail GTFS-RT | Its authenticated static archive contains no route type 0 routes | Rail route `13` is Pascack Valley, not the public archive's Newark Light Rail route `13` |
| Bus G2 | Static routes `HBLR`, `NLR`, and `RvLN`, all route type 0; two `RvLN` vehicle positions matched exact static trips | River LINE GPS observations verified, with source timestamps six seconds behind the feed header |
| Bus G2 trip updates | Four exact NLR trip matches, all stop updates marked `NO_DATA`, without predicted arrival/departure times | These rows cannot populate live arrival boards |

The River LINE vehicles were `Train 3501` and `Train 3511`. Recent GPS timestamps
do not establish that a vehicle is currently carrying passengers or that its
assigned trip still has future stops. No HBLR observations or River LINE trip
updates were present in this snapshot. Live arrival coverage remains unverified
for all three systems; position coverage was observed only for River LINE.

The local ignored `artifacts/` directory preserves the BUSDATA summary,
GTFS-RT reports, authenticated product static archives, and protobuf feed samples.
No authentication responses, credentials, or tokens were saved. The repeatable
read-only commands used for the supplementary check were:

```sh
npx tsx --env-file=.env artifacts/probe-njt-rt.ts > artifacts/njt-gtfsrt-coverage.json
npx tsx artifacts/analyze-njt-g2.ts
```

Those local diagnostic scripts are verification artifacts, not production
pollers. Product-specific static feeds must supply each feed's identity mapping;
public rail route IDs cannot be reused for rail GTFS-RT or bus G2.

## Integration

The bus G2 integration is implemented in the server, web client, iOS app, and
widgets. See [NJT setup, cache behavior, and coverage](njt.md). This initial
coverage snapshot does not promise that every system currently publishes live
predictions. The integration admits explicit realtime timestamps and actual GPS
observations independently, with no schedule fallback.

Rail GTFS-RT and BUSDATA remain researched alternatives. Their different route
identities and ambiguous departure semantics must be verified before any future
source switch. Current production base URLs are
`https://pcsdata.njtransit.com/api/GTFSG2/` and
`https://raildata.njtransit.com/api/GTFSRT/`.
