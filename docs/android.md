# Native Android Development

The Android app is an independent Kotlin and Jetpack Compose client alongside the website and SwiftUI app. It uses the existing normalized transit API. The minimum OS is Android 12 (API 31); the project compiles against API 37.0 and targets API 37.

## Build

Use JDK 17, Android SDK platform 37.0, Build Tools 36.0.0, and platform-tools. The checked-in Gradle wrapper pins its distribution and SHA-256. Dependencies are pinned in the module build files.

On this Mac, `scripts/android-env.sh` selects the task's user-local JDK and SDK when no explicit environment override exists:

```sh
source scripts/android-env.sh
npm run test:android
```

On another machine, set `JAVA_HOME` and `ANDROID_HOME` to your installed toolchains. Install the required SDK packages with your SDK manager:

```sh
sdkmanager "platform-tools" "platforms;android-37.0" "build-tools;36.0.0"
```

The debug APK is `android/app/build/outputs/apk/debug/app-debug.apk`, with application ID `nyc.juliet.subwaysfornerds.debug`. The release application ID is `nyc.juliet.subwaysfornerds`; release signing and Google Play distribution are separate owner-controlled steps. Never commit signing keys or local SDK configuration.

For scrolling measurements and everyday phone use, build the optimized variant:

```sh
source scripts/android-env.sh
./android/gradlew -p android :app:assembleOptimized
bash scripts/install-android.sh android/app/build/outputs/apk/optimized/app-optimized.apk
```

The optimized APK is nondebuggable, enables R8 and resource shrinking, and uses release library variants. It retains the debug application ID and the existing local debug signing key so it can update a debug installation in place without clearing saved data. Use the same signing key that signed the installed APK; a different machine's debug key cannot replace it. Production release signing is unchanged.

`BuildConfig.DEBUG` is `false` in optimized builds, so debug-only fixture intents, endpoint overrides, and simulated-outage controls are disabled. Ordinary debug builds remain available for development and instrumentation. The default `npm run test:android` validation builds debug, release, and optimized APKs. Measure scrolling on the optimized APK and distinguish build-configuration effects from individual source changes; see the [Android performance guidance](https://developer.android.com/develop/ui/compose/performance).

Open `android/` in Android Studio if desired. Android Studio is optional for command-line builds and was not part of the required setup.

## Architecture and Data

- `transit-core` owns Kotlin HTTP contracts, ETags, transit/display rules, portable settings, and account logic.
- `fleet-offline` owns verified downloads, SQLite import/activation, and local fleet queries. Its pinned AndroidX bundled SQLite engine provides consistent JSON query support on Android 12 and newer.
- `app` owns Compose navigation, local storage adapters, location, lifecycle, settings, and Glance widgets.

The production API is `https://subwaysfornerds.juliet.nyc/api/v1/`. The known legacy `https://juliet.nyc/subwaysForNerds/api/v1/` alias is normalized to this origin; unrelated development endpoints remain separate. Source timestamps, arrival times, fetch success, and vehicle positions remain distinct. Times display in `America/New_York`. Cached predictions and car reports retain their provenance; offline history never establishes a current assignment.

The native app covers stations and favorite paging, MTA/SIR/PATH/NJT boards, train details and connections, service changes, station context, fleet history, combined stations, line visibility, and all ten themes. On wide windows, list/detail layouts adapt to the available space.

Settings transfer through the same validated `.nerds` v4 format as web and iOS, including v1–v3 migrations. Imports show a replacement preview before changing saved preferences. Location, credentials, cached transit data, active rides, and downloaded fleet files remain device-local.

Offline cache quotas and retention protect manually saved trips and the active ride. Downloaded fleet browsing supports the full snapshot and v2 equipment/yard selections with 7- or 30-day history, including history beyond the online detail limit. Downloads verify origin, lengths, hashes, schema, counts, and integrity before replacing a usable download.

## Widgets and Permissions

Add the subway widget from the launcher's widget picker after opening the app and saving a favorite. Widgets resize, preserve both directions, support themes and filters, and open the displayed station or saved ride.

Widgets show predicted arrival clock times and source timestamps between refreshes. Imported countdown preferences remain preserved for other clients. Manual refresh and foreground changes can request immediate updates; periodic WorkManager updates use at least 15 minutes, and Android may delay them for power management.

Foreground location supports nearby and closest-station selection. Optional background widget location starts disabled and requires a separate user opt-in and permission. Manual search and a usable saved station remain available when permission is denied or location is unavailable. Coordinates stay on the device.

Lock-screen widget availability depends on the phone and manufacturer. Widget links require normal device authentication before opening the app.

## Optional Accounts

Accounts are optional; offline settings and file transfer work without them. The app checks server configuration and reports account unavailability when authentication is disabled.

Android opens Apple or Google authentication in a system browser through Custom Tabs. The callback `nyc.juliet.subwaysfornerds://auth/android` contains a short-lived, one-use handoff protected by app PKCE, never a session or provider token. Web and iOS authentication retain their existing contracts. Sessions use Android Keystore protection. Sync retains revision checks, pending local edits, explicit initial choices, and user-resolved conflicts.

Live provider acceptance requires real server/provider configuration. Mock and fixture results do not establish live login success.

## Repeatable Verification

```sh
npm run test:android
SFN_ANDROID_SERIAL=emulator-5554 npm run test:android:e2e
npm run check
npm run test:native
```

The Android fixture runner requires an explicit emulator serial and verifies its dedicated AVD name before any fixture reset. The task-created `sfn-android31-native` and `sfn-android36-native` names are recognized; for another dedicated test AVD, also set `SFN_ANDROID_DEDICATED_AVD` to its exact name. Do not select an emulator containing data you want to preserve. Port 8093 is the default; set `SFN_ANDROID_FIXTURE_PORT` to select another free port. The runner uses the recorded API with NJT fixtures and passes a deterministic clock and development endpoint to instrumentation. Physical devices are excluded from the fixture runner.

Logs, HTML/XML reports, screenshots, and APK hashes are retained under `artifacts/android/`. UI tests must distinguish automatic coverage from physical-device acceptance. Test launch overrides require an in-process instrumentation gate in debug builds and are always ignored by release and optimized builds. Ordinary external intents cannot reset app data or select a fixture endpoint.

To install the development APK on an authorized phone without uninstalling or clearing data:

```sh
bash scripts/install-android.sh
```

With multiple connected devices, set `SFN_ANDROID_SERIAL` explicitly. The installer checks the package and OS, updates in place, launches the app, and saves a receipt. A receipt establishes installation and launch, not completed acceptance.

Physical acceptance includes location allowance/denial, keyboard/search, background/resume, favorite/theme/filter persistence, fleet download/update/cancel, airplane-mode relaunch, saved rides, widget placement/resizing/manual refresh, and station/ride links. Record the handset model, Android version, actual results, and unresolved limits in `docs/android-validation.md`.
