# Native iPhone and iPad development

The iOS app is an independent SwiftUI client alongside the React web app. Both use
the existing normalized transit API; the feed pollers and operational fleet database
continue to run on the server. The minimum deployment target is iOS 26.0 (iPadOS 26.0).

## Build and install

Use full Xcode with the iOS SDK and simulator installed. This project uses Swift 6,
automatic signing, Apple frameworks, and the pinned Google Sign-In Swift package.
Xcode resolves its dependencies from the shared Package.resolved file.

1. Open `ios/SubwaysForNerds.xcodeproj` and select the `SubwaysForNerds` scheme.
2. In Xcode Settings > Accounts, sign in with your Apple Account.
3. Select your Personal Team under the app target's Signing & Capabilities.
   For a local override, copy `ios/Config/Local.xcconfig.example` to
   `ios/Config/Local.xcconfig` and enter the team ID. This file is ignored by Git.
4. Connect and trust your iPhone or iPad, enable Developer Mode when prompted, and
   select it as the run destination. Run the app from Xcode.

The default identifier is `nyc.juliet.subwaysfornerds`. If another team already owns
it, use a unique identifier in the local configuration. Do not commit credentials,
provisioning profiles, certificates, or personal team overrides.

Personal Team provisioning expires after seven days; rebuild and reinstall through
Xcode when needed. This is a development installation, without TestFlight or App Store
distribution. See [Apple's account guidance](https://developer.apple.com/help/account/basics/about-your-developer-account).

For a simulator build without signing:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/SubwaysForNerds.xcodeproj -scheme SubwaysForNerds \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

The default API is `https://juliet.nyc/subwaysForNerds/api/v1/`. A Debug-only setting
can select a development API; the phone must be able to reach its address. A phone's
`localhost` is the phone, while simulator localhost reaches the Mac. Prefer HTTPS.
The project permits local networking and does not disable App Transport Security globally.

## Structure and shared contracts

`ios/SubwaysForNerds` owns SwiftUI navigation, screen state, Core Location, themes,
preferences, and board persistence. `ios/TransitCore` owns public Codable contracts,
HTTP/ETag handling, display rules, and testable persistence utilities.
`ios/FleetOffline` owns download integrity, atomic activation, and SQLite queries.

The web and native clients remain separately buildable. Existing HTTP routes and
web base paths retain their contracts. Preferences work locally and transfer between clients through `.nerds` files.
Optional Apple/Google accounts synchronize settings when the server is configured.
See [portable settings and account setup](accounts.md).

| Capability | Web | iPhone and iPad |
| --- | --- | --- |
| Stations, search, favorites, nearby, closest favorite | Supported | Native search and Core Location |
| Grouped boards, route/direction filters, headways | Supported | Native lists and controls |
| Trip stops, operations fields, cars, static pattern, raw data | Supported | Native detail screens |
| Connections and service-change evidence | Supported | Native detail screens |
| Alerts, accessibility, entrances, equipment, outages | Supported | Native screens and external map/source links |
| Fleet filters, grouping, provenance, car/consist history | Supported | Native screens |
| Ten themes | Existing typography and CSS | Equivalent palettes with system typography |
| Saved station boards | Browser storage and service worker | Local files; bundled application shell |
| Download full fleet and retained movement history | Online fleet browsing | Optional download with local search and history |

Times are always displayed in America/New_York. A successful HTTP response does
not renew source timestamps. Cached/stale boards use last-estimate clock times;
cached car assignments are hidden. Offline fleet reports are always historical.
Location permission denial leaves manual station search available.

The compact board keeps station actions and other favorite stations in one row and leaves
the countdown prominent. Direction arrows, line bullets and the board views (Track,
Direction, Families, Corridors, Service) are direct buttons rather than menus. Each station
remembers its view alongside direction and line filters; resetting filters preserves the
selected view. Departures remain chronological within each group, and combined-platform
views show each train's boarding location. Rows show service changes and alerts as icons;
train details list them in full. Smaller visual controls retain 44-point touch targets and
support Dynamic Type.

On iPad, and in any window wide enough for a regular size class, the board and the fleet
list stay on the left while train details, connections, station info or a car's history
fill the right column. Station info shows until a train is chosen. Narrow windows (Split
View, Slide Over, and every iPhone) push the same screens instead. All four orientations are
supported. Command-F opens station search and Command-R refreshes departures.

## Widgets

Add **Closest favorite trains** from the iOS widget gallery after opening the app
once and saving at least one favorite. Home Screen widgets support small, medium,
and large sizes, plus extra-large on iPad. Lock Screen widgets support inline,
circular, and rectangular formats. Every size reserves space for both directions.
Regional stations use their appropriate direction labels; stations with external
departure boards link back to the station in the app.

**Settings > Widgets > Match app filters** chooses the filter source. It starts off.
Independent line filters and Track, Direction, Families, Corridors, or Service
grouping are saved separately for each favorite and shared across widget sizes.
Enabling the toggle uses that station's app line filters and grouping, while
preserving both directions. Switching back restores the independent settings.
Home Screen counts adapt to size; Lock Screen widgets start with up to two
matching trains per direction and have their own density settings. Tapping opens the displayed
station, without automatic closest-favorite startup redirecting the app.

Allow location **While Using the App or Widgets** when iOS asks to extend the app's
location authorization. The widget requests a short location fix when eligible
and selects the closest favorite. Without a current fix, it retains a saved
favorite and displays a location-unavailable label. Without any favorites, it
asks you to add one in the app. Coordinates stay on the device.

**Refresh interval** in **Home Screen display** and **Lock Screen display** sets
each widget type's preferred data reload independently: 1, 2, 5, 10, 15, 30, or
60 minutes. Both default to five minutes, including after upgrading from older
settings. Choices survive relaunch, work with either filter mode, and reset only
with their own display settings. iOS controls the actual schedule and commonly
refreshes widgets every 15–60 minutes; a shorter selection does not guarantee
that frequency. Countdown timers and source-expiry transitions continue between
data reloads. Home Screen widgets have a
refresh button. Feed timestamps retain their existing 90-second freshness limit;
old or offline predictions display labeled last-estimate clock times rather than
continuing to imply fresh arrival predictions. See Apple's
[refresh guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
and [widget location guidance](https://developer.apple.com/documentation/widgetkit/accessing-location-information-in-widgets).

The app embeds the `SubwayWidgets` extension and shares an App Group with it.
Automatic signing provisions both targets. Defaults are
`nyc.juliet.subwaysfornerds.widgets` and `group.nyc.juliet.subwaysfornerds`;
override `SFN_WIDGET_BUNDLE_IDENTIFIER` and `SFN_APP_GROUP_IDENTIFIER` in the
ignored local configuration if needed. Both targets must use the same team and
group. Existing app preferences and fleet downloads retain their original storage.

**Settings > Widgets > Home Screen display** controls compact rows, a
per-direction train limit, and minutes/seconds, minutes, or arrival clock times.
Direction arrows sit beside their columns rather than on a row of their own. Eleven
switches control station names, destinations, tracks, service patterns, car types, car
counts, car numbers, train locations, report times, refresh controls, and grouping labels. Display settings
apply to Home Screen widgets and remain separate from the app-filter matching toggle.
Car reports follow the existing 90-second last-reported and 300-second expiry
rules; offline boards do not show car reports as current. Home Screen widgets
show the selected details, shortened to fit.

**Fit automatically** uses the same ViewThatFits measurement as the Lock Screen to
show as many trains per direction as each widget holds, so large widgets fill their
height; a fixed count is an upper limit. Arrivals keep to a right-aligned column, with
"min" set smaller than the value; clock times omit AM/PM, which the report time
carries, to leave room for destinations. Medium and larger widgets put the report
time beside the refresh button; small widgets put it below the trains. Its dot uses the
theme accent for live predictions and orange for last estimates. When location is
unavailable, small and medium widgets mark the station name with a location-off icon,
and large widgets also spell out the notice. Long station names stay on one line in
small and medium widgets. In medium and larger sizes, text follows Dynamic Type up to
135 percent and fewer trains fit; small widgets keep their size. Extra-large widgets
keep train details on the arrival line. Tinted and clear Home Screens cut route letters
out of their bullets so they remain legible in one color. Where a PATH or light rail
name does not fit beside an arrival, its badge keeps only the line color.

**Settings > Widgets > Lock Screen display** has independent compact spacing,
train count, arrival format, direction order, and information switches. **Show
service icons** is on by default and keeps a small circular B/Q-style line badge
beside each arrival, including compact mode. It can be switched off to leave more
room for times. **Service details (local / express)** separately controls service
pattern text; inferred patterns retain their estimate label. Downtown
is on the left and uptown on the right by default; the order can be reversed.
PATH defaults to New Jersey left and New York right. Circular and rectangular
widgets use two columns; inline widgets list the directions in the selected order.
Circular widgets use the system's circular background and keep their rows inside the
circle; long car details shorten before a train is dropped. Inline PATH and light rail
names are separated from their arrivals by a space.
Choose **Fit as many as possible** to measure the available space and show up to
six trains per direction. The layout uses SwiftUI's
[ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits)
to choose the largest candidate that fits. Fixed counts are upper limits too: the view reduces
them when details or larger text need more room. Hiding information leaves more
room for departures. The rectangular widget can show the station heading;
circular and rectangular widgets can show destinations, tracks, service patterns,
car types/counts/numbers, train locations, and report time. Inline widgets show
arrivals and optional service icons; inline and circular countdowns use rounded minutes.
Compact rectangular widgets put short car and track details beside arrivals.
Compact Lock Screen clocks omit AM/PM to leave room for train information.
Very large text falls back to one arrival per direction without optional details
when needed to retain both directions and the last-estimate label.
Settings migrate from the previously visible Lock Screen fields and are persisted
independently of Home Screen display. Stale predictions always retain their
last-estimate label, even when report-time display is switched off.

Debug builds include **Settings > Widget previews**, which renders the extension's
actual view in every family with live, saved, empty, regional, long-name, and
location-unavailable examples, plus track grouping. Home Screen previews use the
selected app theme and WidgetKit's default 16-point content margins; circular previews
are drawn as circles.
This layout harness complements testing actual widgets in SpringBoard; it does not
simulate WidgetKit's refresh budget, timer layout, or tinted rendering.

## Offline fleet

Settings > Offline fleet shows compressed download size, saved size, and publication time before downloading.
Downloads and updates are explicit; keep the app open while downloading and saving.
A canceled, corrupt, unsupported, or failed update
preserves the previous snapshot. Saved data lives in Application Support, excluded
from device backup, until replaced or deleted.

The snapshot contains every imported car identity, source assertions, last reports,
consist membership, and all retained movement events for the published 30-day window.
Historical records keep their original timestamps. A downloaded window does not silently
advance with the device clock. Local history pagination can read beyond the online
detail endpoint's 200-event limit.

The server streams gzip archives. The app checks transfer size and SHA-256, then
expands in bounded chunks with an exact output limit. Downloads need free space for
the archive plus the expanded database and a 256 MiB reserve; an existing snapshot
stays available throughout an update. Interrupted installation files are removed on
the next launch. The app's privacy manifest declares disk-space checking with Apple's
[E174.1 reason](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
Disk-space information stays on the device.

SQLite is opened read-only. Expanded files are checked against manifest size, SHA-256,
schema version, metadata, table counts, and SQLite integrity before activation.
The activation pointer is replaced atomically after validation. Live data remains
preferred unless saved browsing is explicitly selected or a live request fails.

The server release must contain the new offline endpoints before production downloads
work. Older servers continue to provide live boards and fleet browsing; the app displays
an unavailable download message until the server is updated. See [fleet operations](fleet.md).

## Verification

```sh
npm ci
npm run check
npm run test:native
RUN_WEBKIT=1 npm run test:browser
npm run test:ios
```

Install the pinned Playwright browsers if needed with `npx playwright install chromium webkit`.
The native test script handles Swift Testing macro discovery for command-line tools
and saves logs under `artifacts/`. The UI test script selects an available iOS 26+
iPhone simulator, starts an isolated recorded-fixture API on port 8092, and saves
screenshots and results in a timestamped `.xcresult` bundle. Set `SFN_SIMULATOR_ID`
to use a particular simulator, such as an iPad, to check the side-by-side layout; the
same tests run on both. Port 8092 must be free before starting the script.

Regenerate normalized contract fixtures with `npm run fixtures:native`; the fixture
tests check that the backend and Swift package copies agree. Inputs are recorded
protobuf bytes and synthetic car/context/edge records, without live upstream requests.

For an actual HTTP download/import check, start `node --import tsx test/fixture-server.ts`
in a separate terminal, then run
`SFN_FIXTURE_API=http://127.0.0.1:8092/subwaysForNerds/api/v1/ npm run test:native`.
Stop the fixture server afterward. Restricted environments can instead point
`SFN_FIXTURE_SNAPSHOT_DIRECTORY` at a backend-generated directory containing
`manifest.json` and its `.sqlite.gz` file to check the same import/query/reopen path.

On launch and after returning from the background, the app opens the closest favorite
using device location. A saved catalog works without waiting for a network refresh.
A manual station choice remains selected for that foreground visit; permission prompts
and other temporary inactive transitions do not reset it. If location is unavailable,
the last station remains selected and location is retried on the next foreground visit.

The Board toolbar's location button opens the whole station catalog and requests
your location. All station complexes, including nonfavorites, appear closest first
with straight-line distances. Search can narrow this list, and choosing a station
opens its board. If location is unavailable, the complete searchable catalog and
the location error remain visible.
The location sheet is titled “Stations near you”; ordinary search opens “Find a
station” with favorites first. Each presentation starts with an empty query and
its own sorting mode, so switching between the buttons does not carry either over.

Run `bash scripts/test-native-startup.sh` on a Mac with Xcode to check the actual
startup model against a stalled API and deterministic location, without a simulator.
The UI regression `testClosestFavoriteOnOfflineLaunchAndForegroundReturn` checks the
same foreground behavior through the station controls and Home button.

Debug UI tests use launch environment keys `SFN_API_BASE_URL`, `SFN_RESET_STATE`,
`SFN_DISABLE_LOCATION`, `SFN_TEST_LOCATION` (latitude,longitude), and `SFN_TEST_NOW`.
The injected location is Debug-only. Reset affects only this app's local
application-support folder. Preserve state for offline relaunch scenarios.

Two additional UI tests exercise actual simulator Core Location. After installing
the simulator app, set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
and use your simulator ID for these commands:

```sh
xcrun simctl location "$SFN_SIMULATOR_ID" set 40.730953,-73.981628
xcrun simctl privacy "$SFN_SIMULATOR_ID" grant location nyc.juliet.subwaysfornerds
TEST_RUNNER_SFN_SYSTEM_LOCATION_QA=granted xcodebuild test \
  -project ios/SubwaysForNerds.xcodeproj -scheme SubwaysForNerds \
  -destination "platform=iOS Simulator,id=$SFN_SIMULATOR_ID" \
  -only-testing:SubwaysForNerdsUITests/SubwaysForNerdsUITests/testNearbyUsesSimulatorLocationService \
  CODE_SIGNING_ALLOWED=NO
```

Keep the fixture server on port 8092 running during these tests. For denial,
revoke location with `simctl privacy`, set `TEST_RUNNER_SFN_SYSTEM_LOCATION_QA=denied`,
and select `testNearbySystemLocationDeniedKeepsSearchAvailable`. Both tests skip
without their explicit setup. Afterward, run `simctl privacy` with `reset location`
for this bundle and `simctl location` with `clear` to remove the QA overrides.

Physical-device acceptance still requires a paired phone: location allowance and
denial, keyboard/search, background/resume, themes and filters after relaunch,
fleet download, airplane-mode relaunch, and deletion/re-download. Keep device
results separate from simulator and package results in `docs/validation.md`.

### Repeatable widget QA

Run `bash scripts/test-widgets.sh` for filter persistence, widget deep links,
independent refresh choices through relaunch and reset, Home Screen margins,
column separation and height use, and screenshots of all seven
families and fallback states. Set `SFN_FIXTURE_PORT` to choose an isolated fixture port. Set `SFN_SIMULATOR_ID` to
an iOS 26+ simulator to choose a device. Logs, screenshots, and result bundles are
saved under `artifacts/widgets/`. Do not run another fixture-server test suite on
port 8092 at the same time.

`WidgetHomeScreenTests` is opt-in (`TEST_RUNNER_SFN_WIDGET_HOME_QA=1` when running
`xcodebuild test -only-testing:SubwaysForNerdsUITests/WidgetHomeScreenTests`). Use local simulator signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`)
so App Group entitlements are present. It
places a widget on the simulator Home Screen and verifies shared favorites and
navigation. Run it on the iPhone 17 simulator; the iOS 27 widget gallery fallback
uses its screen dimensions because the remote gallery omits accessible controls.

For spacing reviews, the opt-in `WidgetUXPassTests` (`TEST_RUNNER_SFN_WIDGET_UX_PASS=1`)
save screenshots in the result bundle. `testCapturePreviewGallery` captures the preview
canvas for each family, state, and theme; `SFN_WIDGET_UX_THEMES`, `SFN_WIDGET_UX_FAMILIES`,
and `SFN_WIDGET_UX_SCENARIOS` take comma-separated lists, and `SFN_WIDGET_UX_MODES=0`
skips the tinted and large-text captures. `testRealHomeScreenWidgets` adds each Home
Screen size from the widget gallery with live production departures, captures it, and
removes it unless `SFN_WIDGET_UX_KEEP=1`. With widgets kept,
`testPlacedWidgetsInEachAppearance` captures them under Tinted, Clear, and then
Default, which restores the simulator. `testRealLockScreenWidgets` adds the circular and
rectangular widgets in the Lock Screen editor, captures them, and cancels; the editor
can show a render from an earlier build. Like `WidgetHomeScreenTests`, these need local
simulator signing and the iPhone 17 simulator, and `xcrun simctl install` the new build
first, because `test-without-building` does not always replace an installed app.
Countdown timers can keep SpringBoard from becoming idle, so allow several minutes per
widget size.
