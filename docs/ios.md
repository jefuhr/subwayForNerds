# Native iPhone and iPad development

The iOS app is an independent SwiftUI client alongside the React web app. Both use
the existing normalized transit API; the feed pollers and operational fleet database
continue to run on the server. The minimum deployment target is iOS 26.0 (iPadOS 26.0).

## Build and install

Use full Xcode with the iOS SDK and simulator installed. This project uses Swift 6,
automatic signing, and Apple frameworks only. No CocoaPods or remote Swift packages
are required.

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
web base paths retain their contracts. Preferences are local to each client;
there is no account or cross-device synchronization.

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

Debug UI tests use launch environment keys `SFN_API_BASE_URL`, `SFN_RESET_STATE`,
`SFN_DISABLE_LOCATION`, and `SFN_TEST_NOW`. Reset affects only this app's local
application-support folder. Preserve state for offline relaunch scenarios.

Physical-device acceptance still requires a paired phone: location allowance and
denial, keyboard/search, background/resume, themes and filters after relaunch,
fleet download, airplane-mode relaunch, and deletion/re-download. Keep device
results separate from simulator and package results in `docs/validation.md`.
