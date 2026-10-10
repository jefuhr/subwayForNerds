# Validation

## October 10, 2026 — favorites, widget movement, and native regression audit

### Fixes and failure coverage

- Saved settings now keep a validated redundant snapshot. A damaged primary file
  recovers favorites from it; without a readable snapshot, routine writes preserve
  the unreadable original until an explicit import. Failed preference writes roll
  back the visible star, theme, filters, and widget options and show an error on
  the board. Regression tests cover damaged files, failed writes, and import repair.
- Widget station selection compares fresh locations from the app, extension, and
  other widgets. A slower or location-less refresh cannot overwrite a newer fix.
  Invalid, future-dated, and stale fixes do not pick a station. The loader rereads
  shared settings after waiting for location, including favorite removals.
- The foreground app shares in-flight location requests between startup, nearby
  search, and widgets, and refreshes widget coordinates every 30 seconds without
  changing the manually opened board. Backgrounding cancels the request. Failed
  nearby lookups clear old distances. Saved-favorite widget links also work before
  a station catalog is available and take precedence over startup navigation.
- Account conflict resolution requires an explicit local or remote choice tied
  to the values currently displayed. Empty and stale choices no longer silently
  resolve a conflict. API regression coverage includes malformed responses, ETags,
  cache clearing, station isolation, and HTTP errors.

### Automated checks

- `npm run check`: Passed the web build and all 80 backend tests.
  Evidence: `artifacts/bug-pass/web-check.log`.
- `bash scripts/test-native.sh`: Passed 70 TransitCore tests and 17 FleetOffline
  tests. Evidence: `artifacts/bug-pass/native-final.log`.
- `bash scripts/test-native-startup.sh`: Passed 14 groups exercising the actual
  AppModel, including persistence failures, cold widget links, concurrent location
  consumers, movement, and stale fixes. Evidence:
  `artifacts/bug-pass/startup-final.log`.
- `bash scripts/test-native-account-choices.sh`: Passed both conflict-choice
  regression groups using the actual UI helper. This check is included in CI.
  Evidence: `artifacts/bug-pass/account-final.log`.
- Widget tests reproduced three failures (eight failed expectations) before the
  fixes, then passed afterward. Evidence: `artifacts/bug-pass/widget-tests-before.txt`
  and `artifacts/bug-pass/widget-tests-after.txt`. The account conflict-choice bug
  was also reproduced before its fix in
  `artifacts/bug-pass/account-conflict-before.log`.
- `SFN_SIMULATOR_ID=4B471BAD-EFE7-4069-B98F-F42C73364FC4 SFN_BUILD_JOBS=2 bash scripts/test-ios.sh`:
  The full iPhone run completed with 20 passes, 10 opt-in skips, and one failure in
  the new picker-star test's dismissal step. The test attempted `Done` while iOS
  27 search mode hid that toolbar. It now exits search before dismissing the sheet.
  The favorite itself saved correctly and the selected board remained unchanged.
  Evidence: `artifacts/bug-pass/full-iphone.log`,
  `artifacts/native-ui-20261010-113633.xcresult`, and exported attachments under
  `artifacts/bug-pass/iphone-screens/`.
- The locally signed follow-up passed all four selected UI tests: the corrected
  picker-star workflow, actual granted Core Location, closest-favorite/background
  return, and train/fleet navigation. The latter two also validate hardened waits
  for background suspension and asynchronous fleet loading. The denied Core
  Location test passed separately. Exact commands are preserved in
  `artifacts/bug-pass/run-followup.sh`; logs/result bundles are
  `artifacts/bug-pass/iphone-granted.log` / `.xcresult` and
  `artifacts/bug-pass/iphone-denied.log` / `.xcresult`.
- `SFN_ALLOW_SIMULATOR_STATE_RESET=1 SFN_SIMULATOR_ID=4B471BAD-EFE7-4069-B98F-F42C73364FC4 python3 scripts/test-ios-location-movement.py`:
  Passed using actual simulator Core Location, without the app's injected-location
  test hook. Cold launch selected Times Square, then movement to Union Square
  reached the App Group in **30.03 seconds** while the foreground board stayed on
  Times Square and both favorites stayed saved. This measures shared-state
  publication, not WidgetKit's display latency. Evidence:
  `artifacts/bug-pass/system-location.log` and JSON snapshots/screenshots in
  `artifacts/bug-pass/system-location/`.
- The opt-in `WidgetHomeScreenTests/testWidgetGallerySharedFavoriteAndNavigation`
  passed on the locally signed build: installed the real widget from SpringBoard's
  gallery, displayed Union Square from the shared favorite, opened that station
  when tapped, and removed the test widget. Evidence:
  `artifacts/bug-pass/iphone-home-widget.log` / `.xcresult` and
  `artifacts/bug-pass/home-widget-screens/`. SpringBoard animation waits made this
  320-second run much slower than the in-app preview checks.
- The iPad mini (A17 Pro), iOS 27, passed all seven selected UI tests with zero
  failures or skips: station-specific board views, closest-favorite/background
  return, favorites across changing locations, offline fleet, import preview and
  restore, station search/themes, and train/fleet navigation. Evidence:
  `artifacts/bug-pass/ipad-final.log` / `.xcresult`, `ipad-summary.json`, and
  exported screenshots in `artifacts/bug-pass/ipad-screens/`.
- The final picker-star test also passed on iPad, including staying on the current
  board and preserving the new favorite through offline relaunch. Evidence:
  `artifacts/bug-pass/ipad-picker.log` / `.xcresult` and `ipad-picker-screens/`.
  Across the full run and targeted reruns, 24 distinct iPhone scenarios and eight
  iPad scenarios have passing results. The original test-harness failures remain
  preserved; no failed scenario lacks a passing corrected rerun. Seven extended
  opt-in widget appearance/gallery scenarios were not enabled in this audit.
- `xcodebuild build -project ios/SubwaysForNerds.xcodeproj -scheme SubwaysForNerds -configuration Release -destination 'generic/platform=iOS' -derivedDataPath ios/DerivedData/Simulator -jobs 2 CODE_SIGNING_ALLOWED=NO`:
  Passed the complete unsigned iOS Release app and widget build. This is compile
  validation, not a physical-device install. Evidence:
  `artifacts/bug-pass/release-build.log`.
- Visually reviewed exported screenshots of the remaining favorite after removal,
  medium, large, and rectangular widget previews, the installed Home Screen
  widget, and the iPad board after moving back to Union Square. These are screenshot
  reviews of automated runs, not physical-device/manual interaction acceptance.

### Test environment and limits

- Dedicated iOS 27 iPhone and iPad simulators are used. Previously running
  simulators were temporarily stopped with permission; their data was preserved.
  The initial cold simulator runner crashed before executing tests. A concurrent
  iPad runner stalled during startup and was stopped; device runs were serialized.
- Both task simulators were shut down afterward, location overrides were cleared,
  fixture servers were stopped, and all four previously running simulators were
  booted again. Evidence: `artifacts/bug-pass/restored-simulators.json`. No simulator
  was erased or deleted, and worker worktrees and verification artifacts remain.
- The first two new favorites UI tests failed because their helper expected the
  current station in the shortcut strip. The current station is represented by
  the board's favorite button. The helper was corrected; initial failures remain
  recorded in `artifacts/bug-pass/favorites-ios.log`.
- These checks do not establish physical-device background WidgetKit delivery
  timing or live Apple/Google account authentication. Widget refresh requests
  remain subject to system scheduling. No physical device was installed or changed.

## October 1, 2026 — nearby station simulator QA and correction

- Reproduced the Board location button opening ordinary search on an iPhone 17
  simulator running iOS 27.0. The initial distance-order regression failed because
  the boolean sheet presentation captured the old search mode. Evidence:
  `artifacts/nearby-qa-before.log` and `artifacts/nearby-qa-before.xcresult`.
- Replaced the presentation with an identified search/nearby mode. Nearby requests
  location on opening; ordinary search keeps favorites-first ordering. Queries
  and sorting do not carry between sheet presentations.
- Six targeted simulator UI tests passed with zero failures: all 445 station
  complexes sorted by distance with a nonfavorite first, selecting the nearest
  station, repeated search/nearby openings, unavailable location, closest favorite
  across offline launch/background return, and actual Core Location granted and
  denied paths. These scenarios are covered by four deterministic tests and two
  system-permission tests. Logs and result bundles:
  `artifacts/nearby-qa-final.log` / `.xcresult`,
  `artifacts/nearby-qa-system-location.log` / `.xcresult`, and
  `artifacts/nearby-qa-system-denied.log` / `.xcresult`.
- Visually reviewed exported screenshots in `artifacts/nearby-qa-final-screens`,
  `artifacts/nearby-qa-system-location-screens`, and
  `artifacts/nearby-qa-system-denied-screens`. Nearby shows distances and closest
  first; search shows its quick switches and favorites first. Denied permission
  shows an explanatory error while station search and selection still work.
  Simulator location/permission overrides were reset and the fixture server stopped.
- The corrected signed device build and installation on Juliet's iPhone 17e
  succeeded. Evidence: `artifacts/phone-nearby-fix-build.log` and
  `artifacts/phone-nearby-fix-install.json`. Launch was rejected because the phone
  was locked (`artifacts/phone-nearby-fix-launch.json`); this update's interactions
  were verified in the simulator, not on the physical device.

## October 1, 2026 — signed iPhone installation

- After workspace permissions were updated, the signed Debug device build succeeded
  with `xcodebuild` using the `SubwaysForNerds` scheme and
  `ios/DerivedData/Phone`. Output: `artifacts/phone-rebuild-latest.log`.
- `devicectl device install app` successfully installed the latest app on Juliet's
  physical iPhone 17e, including the closest-favorite lifecycle fix and the Board
  location button. Receipt: `artifacts/phone-install-latest.json`.
- After the phone was unlocked, the app launched successfully. A console launch
  (PID 66155) remained running across subsequent process inspections, and no
  matching app crash report was returned by the available diagnostic listing.
  Evidence: `artifacts/phone-console-latest.log`, `artifacts/phone-processes-all.json`,
  and `artifacts/phone-process-filter-check.json`. This is launch verification;
  nearest-station and other physical-device interaction acceptance remain manual.
- Launch attempts while the device was locked were rejected with
  `FBSOpenApplicationErrorDomain`, code 7, `Locked`. The phone locked again before
  a final standalone relaunch; that request terminated the console-monitored app
  before its launch was rejected. The installed update remains available to open
  from the phone. Latest receipt: `artifacts/phone-launch-latest.json`.

## October 1, 2026 — native closest favorite startup and nearby button

- `bash scripts/test-native-startup.sh` passes seven checks using the actual
  `AppModel`: closest of two favorites while the catalog request is stalled,
  manual choice preserved through temporary inactivity, closest favorite selected
  again after backgrounding, last station retained without favorites, and last
  station retained with location disabled, nearby search obtaining location while
  keeping the full catalog including nonfavorites, and unavailable nearby search
  keeping the catalog with an explanatory error. The test uses a temporary state directory,
  Debug-only coordinates, and a URL protocol that stalls network requests.
  Output: `artifacts/closest-favorite-model-tests.log`.
- The app typechecks for iOS in Debug and Release. The UI regression typechecks
  against the simulator SDK. Outputs: `artifacts/closest-favorite-typecheck.log`
  and `artifacts/closest-favorite-uitests-typecheck.log`.
- The UI regression `testBoardLocationButtonListsAllStationsByDistance` covers
  opening nearby search directly from the board, a nonfavorite station ranking
  before a farther favorite, and choosing that station. The permission fallback
  regression also enters the catalog from the board's location button.
- The simulator regression could not run: Xcode package resolution cannot write
  SwiftPM diagnostics under `~/Library/Caches/org.swift.swiftpm`. The exact attempt
  is recorded in `artifacts/closest-favorite-ui.log`. These checks do not establish
  simulator or physical-device acceptance. This initial check preceded the signed
  iPhone installation recorded above.

## September 6, 2026 — initial validation

- Production TypeScript/Vite build passes.
- 17 data/API regression tests pass, including all nine recorded protobuf feeds,
  present/absent extension fields, stable identity, track mismatches, stale and
  failed feeds, station-complex separation, Brighton/Lex local–express inference,
  compatible static patterns, direct-train ranking and conditional HTTP requests.
- 12 Playwright checks pass across desktop Chromium and mobile Chromium: board
  rendering, keyboard dismissal, search, favorites, restoration, route/direction
  filters, ten themes, train/station panels, denied geolocation and offline PWA
  recovery. No horizontal overflow at 1440px or 390px in the captured views.
- Live requests successfully decoded all eight subway/SIR feed groups and subway
  alerts. The catalog contains 445 complexes / 496 constituent stations. A live
  Union Square station-context response returned nine entrances, seven equipment
  records and two outage records; these counts are a snapshot, not current advice.
- Regular and supplemented GTFS downloads and worker-thread parsing succeeded.
  All adjacent stop pairs in the three curated corridors were verified against
  the downloaded GTFS stop sequences, including Brighton's curved southern end.
- `npm audit` reports zero vulnerabilities.

## Performance

Measured against the local production server with live polling active. The API
test sends 500 requests with 50 concurrent clients. Browser measurements use a
390×844 viewport, 70ms emulated network latency, 10Mbps download, 4Mbps upload,
and 4× CPU throttling. The mark records the first React layout commit containing
train rows; it is not an on-device paint measurement. Each cold run uses a fresh
browser context. Repeat runs use the installed, versioned service-worker shell.

| Measurement | Result | Target |
| --- | --- | --- |
| Station API p50 | 34ms | — |
| Station API p95 | 75ms | <100ms |
| Cold usable board, five runs | 546–581ms | <1500ms |
| Cached repeat board, five runs | 148–175ms | <200ms |

These measurements came from the September 6 05:52 UTC benchmark. They describe
this machine/profile, not a guarantee of network speed or MTA source freshness.
`scripts/benchmark.mjs` reproduces the checks and records `artifacts/performance.json`.

## Environment limitations

The host is Arch Linux with no Docker daemon or Compose plugin. Docker/Compose configuration is
provided but the image has not been built or run here. The non-container production
server was exercised directly.

Chromium required isolated runtime libraries and fonts under
`/tmp/subway-browser-libs.R6e8QX`; no system packages were installed. The tests ran
with that directory's `usr/lib` in `LD_LIBRARY_PATH` and its `fonts.conf` in
`FONTCONFIG_FILE`. These are local environment accommodations, not app dependencies.

WebKit downloaded successfully, but the Ubuntu fallback binary needs additional
GTK/GStreamer/ICU/codec libraries absent on this unsupported host. iOS Safari and
physical home-screen behavior have not been verified. On a supported machine:

```sh
npx playwright install --with-deps chromium webkit
RUN_WEBKIT=1 npm run test:browser
```

The initial local verification did not modify the live site, DNS, or reverse proxy.

## Production deployment preparation

The existing juliet.nyc host uses Node 22 and a dedicated systemd service at
`/opt/subways-for-nerds`; its nginx prefix already matches this build. The runtime
lockfile matches the installed dependencies. The initial deployed revision serves
the API but has no built frontend.

For the host's 2GB RAM budget, schedule archives are now parsed sequentially and
CSV input is chunked into 64KiB blocks. A live refresh of both archives completed
in 9.9 seconds at 377MB process peak RSS in the isolated local worker check,
producing 257 regular and 258 supplemented patterns.

## September 28, 2026 — native iPhone and web support

### Verified locally

- TypeScript checks and the production Vite web build pass. The web application
  source and existing static assets remain unchanged.
- All 54 backend tests pass, including consistent full-history gzip exports,
  concurrent board requests and WAL writes, byte ranges, checksums, failed export
  recovery, retention limits, and low-space failures during export/compression.
  Evidence: `artifacts/validation-backend-gzip.log`.
- The production-preserving overlay passes all 67 tests under Node 22, including
  its existing analytics, PATH, and NJ Transit coverage. Its web build also passes.
  Evidence: `artifacts/deploy-native-fleet/validation-node22-gzip.log` and
  `validation-build-gzip.log` in the same directory.
- TransitCore passes 20 tests, including backend-generated JSON contracts,
  regional station behavior, ETags, opaque identifiers, stale-source display,
  persistence, and raw/gzip manifests above 2 GB.
- FleetOffline passes 16 enabled tests. Coverage includes bounded gzip inflation,
  truncation and trailing bytes, checksums, disk budgets, cancellation during SQLite
  work, interrupted installation cleanup, indexed history pagination, and restoring
  a real backend-generated 8,442-car snapshot. One HTTP-only test is skipped in
  this final run because local listener access is restricted. That HTTP scenario
  passed against the earlier raw-snapshot fixture before the transport changed.
  Evidence: `artifacts/TransitCore-tests.log` and `FleetOffline-gzip-tests.log`.
- The latest TransitCore and FleetOffline modules compile against iPhoneOS 27 with
  an iOS 26 deployment target. The complete SwiftUI application typechecks in
  Debug and Release with Swift 6 strict concurrency. Exact commands and output:
  `artifacts/ios-typecheck/verify.sh` and `verification.log`.
- Complete unsigned device and simulator test-bundle builds succeeded before the
  final gzip changes. These are compile results, not simulator/device acceptance.
- The last full browser run reached 36 of 45 cases: 33 passed and three expected
  platform skips before interruption. A separate focused run passed four cases,
  including WebKit offline recovery and narrow views, with two platform skips.
  This is not a complete final browser-suite pass. Logs are retained under
  `artifacts/browser-regressions/`.

The native package tests used workspace cache paths and SwiftPM's
`--disable-sandbox` option to avoid its redundant nested macOS sandbox. The outer
workspace restrictions remained active. No third-party packages or system dependencies were added.

### Remaining acceptance and release work

- Phone installation is not verified. Xcode recognizes the trusted phone and the
  Personal Team was configured locally. The last signed rebuild reached Apple's
  keychain-controlled codesign step; the user deferred local approval. The source
  has changed since that build, so build the latest project before installing.
- Native UI tests compile but have not run. The iOS simulator runtime download
  failed during registration with a missing personalization manifest, and current
  execution permissions deny CoreSimulator access. The final full `xcodebuild`
  retry is also blocked from writing its protected SwiftPM diagnostics cache.
- Final browser and actual HTTP download reruns cannot start a local listener
  under the current execution restrictions. The final attempted browser log is
  `artifacts/browser-regressions/final-audit.log`.
- Test the phone's location allowance/denial, keyboard, background/resume,
  preferences after relaunch, fleet download, airplane-mode relaunch, and deletion.
  Simulator checks do not replace this acceptance.
- Production was inspected read-only. It is newer than this checkout, so a release
  must preserve its web/analytics/PATH/NJT changes. The reviewed eight-source-file
  overlay, baseline checksums, and rollback helper are prepared under
  `artifacts/deploy-native-fleet/release/`. No production deployment occurred.
- The production database was about 12 GB with about 22 GB free. The first real
  export still needs a size/duration/space check after deployment approval. The
  8.8 MB fixture compressing to 1.1 MB does not predict production behavior.

Normal-machine commands remain `npm run check`, `RUN_WEBKIT=1 npm run test:browser`,
`npm run test:native`, and `npm run test:ios`. See [iPhone setup](ios.md) for signing
and simulator configuration.

## September 28, 2026 — compact board and departure views

- Replaced the large Board title with inline navigation, combined station actions,
  reduced secondary text and spacing, and emphasized departure countdowns. Route
  buttons retain 44-point hit areas; station controls adapt for larger text.
- Added the production web board's five views: track, direction/all platforms,
  route families, station corridors, and service. Views persist per station and
  migrate existing preferences without resetting favorites or filters. Combined
  views show each train's boarding context, without duplicate track labels.
- All 31 TransitCore tests pass, including 11 new grouping, ordering, preference,
  and boarding-label cases. Evidence: `artifacts/board-ordering-tests.log`.
- Full app source typechecking passes for Debug and Release against the iPhone SDK;
  the UI tests also typecheck against the simulator SDK. Logs:
  `artifacts/board-compact-typecheck.log` and
  `artifacts/board-compact-uitests-typecheck.log`.
- Added a UI scenario for initial departure visibility, all five menu choices,
  per-station persistence, and screenshots. It has not executed: this session
  still cannot connect to CoreSimulator.
- The user's phone screenshot and earlier install log confirm the prior app is
  installed. This compact-board update has not been installed from this session:
  the build fails when Xcode writes its protected SwiftPM diagnostics cache.
  Evidence: `artifacts/board-compact-device-build.log`. Run the latest project
  in Xcode to install and visually verify this update.
- This follow-up changes native UI/contracts only; web and backend source remain
  unchanged from the preceding implementation.

## October 5, 2026 — closest-favorite widgets

- Added Home Screen small, medium, large, and extra-large widgets and Lock Screen
  inline, circular, and rectangular widgets. Both directions remain visible;
  nearest-favorite selection, per-station filters, and global display settings
  share an App Group with the native app. Existing app preferences retain their
  storage and decode defaults for new widget settings.
- TransitCore: 39 tests passed, including eight widget cases for filter modes,
  nearest-favorite fallback, balanced directions, cache isolation, car-report
  freshness, setting migration, deep links, and local timeline transitions.
  Evidence: `artifacts/widgets/core-dense-final.log`.
- FleetOffline: all 17 tests passed. Native startup integration checks passed,
  including independent filter persistence and widget navigation taking priority
  over closest-favorite startup. Evidence: `artifacts/widgets/native-dense.log`
  and `artifacts/widgets/startup-dense.log`.
- Four focused simulator UI tests passed: all seven view families and fallback
  states, independent filters across mode changes and relaunch, display-setting
  persistence and hidden fields, and widget deep links. Evidence:
  `artifacts/widgets/ui-20261005-111133.xcresult` and `ui-latest.log`.
  Initial iPad family layout checks also passed (`ipad-layout.xcresult`); the
  final denser extra-large layout has not been rerun on iPad.
- Web build and 54 server tests passed. The final browser regression run passed
  41 tests with four intentional project-specific skips. The service-change
  freshness test now prepares its mock board once and advances report age without
  firing competing polling requests. Evidence: `web-check.log` and
  `web-fixed-final.log` under `artifacts/widgets/`.
- Signed Debug and Release device builds passed. The final Debug app, including
  the widget extension and matching App Group entitlements, was installed and
  launched on the user's iPhone. Evidence: `phone-complete-build.log`,
  `phone-complete-install.log`, and `phone-complete-launch.log`.
- Remaining QA: the opt-in SpringBoard integration test has not passed. Unsigned
  simulator builds omit App Group entitlements; local signing is required. The
  latest locally signed attempt stopped because its app-icon query also matched
  an existing widget (`home-verified.log`, line 55). Earlier attempts exposed
  remote gallery accessibility gaps and the widget location consent prompt.
  Home Screen sharing and navigation still need an end-to-end pass; view previews
  and the successful device launch do not establish that result.

## Pull request CI

`.github/workflows/pr-checks.yml` runs on every pull request (including drafts),
main-branch pushes, and manual dispatch. `Web E2E (Chromium and WebKit)` builds
and runs server tests, then executes desktop Chromium, mobile Chromium, and mobile
WebKit against the recorded fixture server. CI rejects focused `.only` tests and
publishes the Playwright HTML report, failure screenshots, and traces.

`iOS simulator E2E` uses GitHub's `macos-26` runner and its selected Xcode, runs
Swift package/startup integration tests, then the normal iPhone simulator suite.
This includes widget view families, display/filter persistence, and deep links.
The SpringBoard widget-placement and manually configured system-location tests
remain opt-in and are not covered by the required suite. No Apple signing secrets
or physical device are needed for these unsigned app-view tests.

Both jobs preserve reports for 14 days, including on failure. New commits cancel
older runs for the same pull request. To enforce them before merging, configure
branch protection to require the two job names; this workflow does not change
repository branch-protection settings. GitHub's current runner inventory is
[documented here](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

## October 5, 2026 — two Lock Screen departures per direction

- Inline, circular, and rectangular widgets now select the two soonest matching
  departures in each direction. Lock Screen counts stay at two independently of
  Home Screen density/count settings; missing departures use an empty slot in
  circular/rectangular layouts. Car details remain subject to display settings
  and the existing report freshness rules.
- The focused simulator E2E test passed. It checks all four departure slots in
  circular and rectangular views, the exact inline list, and the last-estimate
  label for saved predictions. Screenshots were exported and visually reviewed.
  Evidence: `artifacts/widgets/lock-20261005-191229.xcresult`, `lock-ui.log`, and
  `lock-screens/`. This checks the shared widget views, not placement on the
  system Lock Screen. The test is included in the normal PR iOS suite and the
  focused widget QA script.

## October 5, 2026 — independent Lock Screen customization and service icons

- Lock Screen display now has independent spacing, arrival format, train count,
  direction order, and information settings. Downtown defaults to the left and
  uptown to the right. Automatic density measures the available space and tries
  up to six departures per direction; fixed counts are also reduced when needed
  to fit. Very large text retains both directions and the last-estimate label.
- Service icons are enabled by default. Compact circular, rectangular, and inline
  views use small B/Q-style circular badges beside arrivals. The icon toggle is
  independent of the local/express service-detail toggle. Older preferences
  migrate without resetting Home Screen display or saved route filters.
- All 42 TransitCore tests and nine native startup integration checks passed.
  Coverage includes migration, direction order, density limits, independent
  persistence through relaunch and the shared App Group snapshot, hidden service
  details, and inferred-pattern estimate labels. Evidence:
  `artifacts/widgets/core-service.log` and `startup-service.log`.
- All seven focused widget simulator E2E tests passed with zero failures.
  They cover every widget family and fallback state, Home Screen and Lock Screen
  independence, more than two departures per direction, both direction orders,
  arrival formats, large text and row bounds, compact service icons, hiding icons,
  persistence, filters, and deep links. Evidence:
  `artifacts/widgets/ui-20261005-195457.xcresult` and `ui-latest.log`.
  Exported screenshots in `ui-20261005-195457-screens/` were visually reviewed for
  compact icons, default counts, maximum density, clocks, and large text.
  A final run of the three Lock Screen cases also passed against the final source:
  `lock-service-final-20261005-200141.xcresult` and `lock-service-final-ui.log`.
  Its exported inline screenshots were visually reviewed with two and three
  arrivals per direction. The repeatable command is saved in
  `artifacts/widgets/verify-lock-final.sh`.
- The final signed Debug app and widget extension built successfully and were
  installed wirelessly on the user's iPhone. Launch succeeded; both the app and
  widget extension appeared in the subsequent process inspection. CoreDevice
  reported `localNetwork` transport. Evidence under `artifacts/widgets/`:
  `phone-lock-custom-build.log`, `phone-lock-custom-install.json`,
  `phone-lock-custom-launch.json`, `phone-lock-custom-processes.json`,
  `phone-lock-custom-processes-final.json`, and `phone-lock-custom-device.json`.

The simulator checks exercise the extension's shared view through the Debug
preview harness. They do not establish widget placement or interactions on the
system Lock Screen; the device check establishes installation and launch.

## October 5, 2026 — widget spacing and SpringBoard review

- Home Screen widgets now fit their trains to each size: direction arrows sit in a gutter
  beside each column, arrivals keep to a right-aligned column, details align with
  destinations, and medium and larger sizes put the report time beside the refresh
  button. **Fit automatically** uses ViewThatFits, so the iPhone 17 large widget shows
  eight trains per direction instead of six above a blank band; medium keeps three and
  small keeps two. Route bullets cut their letters out on tinted and clear Home Screens.
- Real widgets were placed on the iPhone 17 simulator (iOS 27) Home Screen with live
  production departures, before and after the change. The baseline showed defects that
  the in-app preview did not: countdown timers were laid out at their widest width and
  floated after the destination, route letters drew at regular weight, and the small
  widget's title sat about 10 points from the top edge against about 17 at the sides.
  All three are fixed in the final captures. Measured sizes on this simulator: medium
  349.67 × 164.33, large 349.67 × 365, circular 72 × 72, rectangular 162 × 72 points.
- Default, Clear, and Tinted Home Screen appearances were captured with the widgets
  placed; cut-out route letters remain legible on Clear and Tinted. The simulator was
  returned to Default. Lock Screen widgets were added in the system editor and captured
  there, then discarded with Cancel. That pass found circular arrivals truncated by the
  first draft's inset. The circle now insets its rows by 10 points, and the UI test
  checks circular rows against the circle rather than a square. A rendered probe showed
  that the Lock Screen draws accessory text at the same scale as the preview (1.00).
  The editor also showed renders from earlier builds, so the final circular train count
  was confirmed in the preview at the real 72-point size: two trains per direction with
  shortened car details.
- With the first draft's longer candidate lists, the widget extension rendered timeline
  entries at a median interval of 114 ms (26 to 34 entries per reload). Caching the
  clock-time formatter and starting each size one train above its usual capacity brought
  the median to 37 ms. Evidence from the simulator's unified log:
  `artifacts/widget-ux/render-cadence-before.txt` and `render-cadence-after.txt`.
- All 43 TransitCore tests and the nine native startup checks passed
  (`artifacts/widget-ux/TransitCore-final.log`, `native-startup-final.log`).
- `bash scripts/test-widgets.sh` passed all eight widget UI tests on the iPhone 17
  simulator, including the new Home Screen margin, column, and height test:
  `artifacts/widgets/ui-20261005-234347.xcresult` and `ui-latest.log`, with exported
  screenshots in `ui-20261005-234347-screens/`. SpringBoard captures are under
  `artifacts/widget-ux/`: baseline `explore2-212438-screens/`, final
  `real-final-233907-screens/` and `final-real-home.png`, appearances
  `appearance-v9-223923-screens/` and `appearance-v10-224134-screens/`, and the Lock
  Screen editor `lock-real5-233135-screens/`. The opt-in `WidgetUXPassTests` repeat them.

The SpringBoard passes use live production departures, so their contents vary between
runs. The simulator's location override and permission granted for these passes were
reset afterward.


## October 6, 2026 — portable settings and optional accounts

- `npm run check` passed the production web build and all 64 backend/shared tests.
  Account coverage includes signed-token validation, replay and browser binding,
  CSRF, explicit linking, revision checks, session invalidation, deletion, durable
  encrypted grants, and rejection of an incorrect encryption key. The focused
  account suite also passed after the final database-permissions adjustment.
- `npm run test:native` passed 43 TransitCore and 17 FleetOffline tests.
  `bash scripts/test-native-startup.sh` passed, including bounded `.nerds` reading,
  preview without mutation, atomic replacement, widget sharing, relaunch, and
  failed-write recovery. Shared TypeScript and Swift `.nerds` fixtures match.
- The full browser run passed 46 tests with four expected skips and one WebKit
  offline file-injection failure. The test now selects the file before taking
  the browser offline and commits the import while disconnected. All 15 focused
  settings tests then passed across desktop Chromium, mobile Chromium, and mobile
  WebKit, including conflict resolution, account-switch isolation, storage failure,
  and the standalone privacy page under the installed service worker.
- The native `.nerds` UI test passed after allowing the simulator’s Files picker
  time to initialize. It checks cancellation, replacement, relaunch persistence,
  and presentation of the export picker; the export screenshot was visually
  reviewed. Evidence: `artifacts/accounts/ios-focused-3.xcresult` and
  `artifacts/accounts/ios-focused-attachments/`. The initial full native run
  passed 12 tests, skipped three opt-in tests, and failed the initial export-picker
  wait and a widget-toggle assertion. The final focused widget test passed with
  a settled-navigation wait and a tap on the switch thumb, verifying display
  changes and relaunch persistence. That run rebuilt the final app successfully:
  `artifacts/accounts/ios-widget-final.xcresult` and `ios-widget-final.log`.
- Evidence is retained in `artifacts/accounts/`, `playwright-report/`, and
  `test-results/`. Native simulator results are in `.xcresult` bundles, with
  screenshots and recordings exported under `artifacts/accounts/ios-attachments/`.
- Real Apple/Google authorization, signed-device callbacks, and provider revocation
  still require owner enrollment and credentials. Authentication defaults to off;
  setup and rollout instructions are in `docs/accounts.md`. Mocked backend/browser
  checks do not establish a live-provider pass.

### PR integration with the latest main branch

Merged the independent Lock Screen customization changes before opening the PR.
The portable schema now carries Lock Screen display options, direction order, and
service icons. Older v1 files migrate their previous display settings consistently
in Swift and TypeScript. Both shared fixtures exercise customized Lock Screen values.

After integration, the web build and all 65 backend/shared tests passed, all 48
TransitCore and 17 FleetOffline tests passed, and the AppModel startup integration
checks passed. All 15 focused browser settings tests passed across Chromium and
WebKit. The native app and UI test bundle compiled with `build-for-testing` for
the generic iOS Simulator destination. The earlier native UI results above
predate this merge; the merged UI suite is left to PR CI. Logs are retained as
`artifacts/accounts/merge-*.log`.
## October 6, 2026 — widget review and independent refresh intervals

- Reviewed Claude's widget spacing and density change (`0c896f5`) and the shared
  rendering code. No functional blocker was found; removed an unnecessary
  `nonisolated(unsafe)` annotation from the cached, Sendable DateFormatter.
- Added separate preferred refresh intervals to Home Screen and Lock Screen
  display settings: 1, 2, 5, 10, 15, 30, and 60 minutes. The timeline provider
  uses the Lock Screen choice for all three accessory families and the Home
  Screen choice for system families. Missing or unsupported interval values
  default to five minutes without discarding existing display settings. Local
  countdown/source-expiry entries and manual refresh remain available.
- TransitCore passed 46 tests, including legacy-display migration, independent
  App Group persistence, and round trips for every interval. Evidence:
  `artifacts/widgets/refresh-core.log`; the test-before-implementation failure
  is retained in `refresh-core-red.log`.
- Nine actual AppModel startup checks passed, including independent intervals
  through filter-mode toggles, relaunch, and shared snapshot persistence.
  Evidence: `artifacts/widgets/refresh-startup-final.log`.
- The isolated widget review passed seven of eight UI tests on an iPhone 17e
  simulator with iOS 27. The first information-toggle tap failed to change its
  value; that case passed on the new settings layout without a test change.
  An earlier run was interrupted by concurrent app installation. Preserved
  results: `artifacts/widgets/review-isolated-20261006-072502.xcresult`, its
  exported screens, and `review-termination-reasons.log`.
- All three focused UI cases passed on the refresh build: independent refresh
  persistence/reset, hidden-information persistence, and Lock Screen maximum
  density. Evidence: `artifacts/widgets/refresh-ui-20261006-074327.xcresult`.
  The final strengthened reset test also passed, verifying that resetting Lock
  Screen settings retains a different Home Screen interval. Evidence:
  `artifacts/widgets/refresh-final-20261006-074847.xcresult`, exported screens,
  and repeatable `verify-refresh-final.sh`. These inspect the app settings and
  shared widget views; they do not establish iOS's background refresh cadence.
- The reviewed spacing build was installed wirelessly on the iPhone 17e and
  launched; subsequent inspection confirmed the app still running. Evidence:
  `artifacts/widgets/phone-review-install.json`, `phone-review-launch.json`, and
  `phone-review-processes-final.json`.
- The build including refresh settings passed signed device compilation and
  strict signature verification; app and extension have matching App Groups.
  Evidence: `artifacts/widgets/phone-refresh-generic-build.log` and
  `phone-refresh-signature.log`. Its installation remains pending: the phone
  became unavailable, and CoreDevice rejected installation with error 4016.
  Evidence: `phone-refresh-install.log` and `phone-refresh-device-final.json`.
