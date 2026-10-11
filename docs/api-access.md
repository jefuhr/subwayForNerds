# Transit API access research

Checked October 10, 2026. This records published documentation and the remaining
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

Account approval was confirmed, but not product entitlement or a
working token. No authenticated request was made. A later integration should
first verify BUSDATA entitlement and actual light rail response coverage with
the account, then map official stop/route/trip identities against the rail GTFS
archive and label schedule-only results accordingly. This change intentionally
leaves the existing light rail behavior in place.
