# Android Implementation Contract

The coordinator owns Gradle, manifests, CI, scripts, fixture generation, documentation, and final integration. Workers start at `6c18ea679daba21b6e0d77dfc2c823875454c376`, work only in their assigned Orca worktree, and never commit, push, deploy, publish, or create a PR. Approved native dependencies are authorized; ask the coordinator before additional packages. Prefer tabs where supported.

## Ownership

- Core worker: `android/transit-core/src/**`, Android account server support, and its focused server tests. Package `nyc.juliet.subwaysfornerds.core`. Own DTOs, HTTP/ETags, portable settings v1-v4, display/grouping/station-selection rules, and pure account/sync logic.
- Persistence worker: `android/fleet-offline/src/**`, app `data/**`, `location/**`, and `widgets/runtime/**`. Own local settings/session storage, station/trip cache, fleet download/import/query, location policy, and widget scheduling. Exclude rendering and UX.
- UX worker: app `MainActivity.kt`, `SubwaysApplication.kt`, `ui/**`, `widgets/ui/**`, UI resources, and app UI/instrumentation tests. Own all UX, themes, navigation, ViewModels, lifecycle/screen wiring, Glance rendering, previews, and visual acceptance. Exclude persistence, core DTOs, fleet internals, and server edits.
- Report ownership conflicts and public interface changes through Orca. Workers may read the coordinator checkout but must never write there. The coordinator distributes scaffold copies and integrates accepted results.

## Integration interfaces

Core exports serializable DTOs named after existing TypeScript/Swift contracts: Station, StationPart, Board, Departure, Train, TripDetail, TransferResult, StationContext, FleetPage, FleetDetail, FleetOfflineManifest, FleetPackSelection, FleetPackManifest, FleetPackJob, Settings, NerdsFile. Preserve exact JSON properties, absent/false/zero semantics, and unknown station/theme identifiers. Core publishes any additional helper signatures early.

`TransitClient(baseUrl: String = PRODUCTION_API_BASE)` has suspend stations(), board(stationID), trip(key), transfers(key, stopID, sequence?), context(stationID), fleet(query: Map<String,String>), fleetDetail(kind,id), offlineManifest(), prepareFleetPack(selection), fleetPackStatus(jobID). Default API: https://subwaysfornerds.juliet.nyc/api/v1/. Normalize only the known legacy https://juliet.nyc/subwaysForNerds/api/v1/ alias to this production origin; custom endpoints remain distinct. `NerdsCodec.decode(text)` returns NerdsFile; encode(settings,lastStation) writes v4. Validate the 1 MiB limit, migrations, and three-way sync conflicts.

Persistence exports:
- `data.AndroidSettingsStore(context)`: suspend load(): Settings, save(settings), lastStation(): String, saveLastStation(id).
- `data.AndroidSessionStore(context)`: suspend loadToken(): String?, saveToken(token), clear().
- `data.AndroidTransitCache(context, apiBase: String)`: suspend saveBoard(board), loadBoard(stationID): Board?, saveTrip(trip,manual: Boolean = false), loadTrip(key): TripDetail?, savedTrips(): List<TripDetail>, setActiveRide(key: String?), activeRide(): TripDetail?, removeTrip(key), clearAutomatic(). Atomic writes and protected trip retention are required. Publish extra quota/planner APIs early.
- `fleet.OfflineFleetStore(context)`: suspend manifest/status, download/install, clear, fleet(query), fleetDetail(kind,id). Publish concrete signatures early.
- `widgets.runtime.WidgetRuntime.read(context): WidgetSnapshot`, suspend refresh(context), schedule(context). WidgetSnapshot includes station ID/name, theme ID, north/south rows, source time, notice, and optional ride key. WidgetDeparture includes route, destination, arrival Unix seconds, boarding area, and historical detail text. Agree additional presentation fields through Orca. UX owns `widgets.ui.TransitWidgetReceiver` and rendering; runtime owns provider-independent work/actions.

## Behaviors

Full current iOS parity includes MTA/SIR/PATH/NJT, station paging, all board views and filters, train/car/consist favorites, combined stations/global hidden lines, operations/raw trip details, service changes, connections, station context, offline stations/saved rides, fleet selections, .nerds, and optional accounts. Preserve all ten themes with Android controls, 48 dp targets, TalkBack, large text, and adaptive list/detail layouts.

Times use America/New_York. HTTP success never renews source timestamps. Preserve source-specific freshness, independent NJT prediction/GPS clocks, labeled offline estimates and passed predictions, unknown equipment health, and historical car reports. Never invent schedule arrivals, cancellations, or current fleet reporting from cache.

Fleet supports full v1 SQLite snapshots and v2 filtered JSONL gzip packs, equipment/yard selections, 7/30-day histories, same-origin downloads, bounded expansion, exact hashes/counts/schema checks, atomic activation, and history beyond 200 events. Downloads are explicit and foreground-bound, matching iOS. Failed/canceled updates preserve the previous download.

Widgets reserve both directions, apply filters/themes/display fields and active-ride preference, and show arrival clocks/source timestamps even if portable settings request countdowns. Never rewrite unsupported portable preferences. Refresh on foreground/manual events and use WorkManager at max(15,preferredInterval) minutes. Optional background location starts disabled with an explicit permission flow. Denial/unavailability retains a usable station and honest notice. Lock-screen availability is OEM-dependent; app deep links require normal authentication.

Write focused tests before new logic where practical, use recorded/synthetic fixtures and deterministic clocks, and retain logs/reports/screenshots. No live upstream requests in isolated tests, production mutations, SSH tunnels, destructive device resets, or unrelated iOS/web edits. Escalate consequential ambiguity.
