# Android Validation

Updated October 14, 2026. The native Android app and widgets are implemented and staged for review. The authorized GPT-6 Astra `max` correction pass closed all five prior P2 findings. Coordinator builds, lint, fresh app unit tests and selected native workflows pass on the final combined source. Android 12–14 account-encryption policy and physical manual acceptance remain pending; this is not full product acceptance.

Base revision: `6c18ea679daba21b6e0d77dfc2c823875454c376`. No commit, push, PR or deployment was performed. The owner explicitly approved the pinned `androidx.sqlite:sqlite-bundled:2.6.2` dependency and the Astra model substitution. The substitution does not approve any security-policy change.

## Final Coordinator Results

| Check | Result | Evidence under `artifacts/android/` |
| --- | --- | --- |
| App JVM | **124 passed**, zero failures/errors/skips; freshly executed on the final combined source | `astra-correction-pass/combined-build/app/xml/` |
| Transit core JVM | 37 passed in retained unchanged-source XML; Gradle reported `UP-TO-DATE` in this pass | `astra-correction-pass/combined-build/transit-core/xml/` |
| Fleet JVM | 12 passed in retained unchanged-source XML; Gradle reported `UP-TO-DATE` in this pass | `astra-correction-pass/combined-build/fleet-offline/xml/` |
| Build | Debug, unsigned release and instrumentation APKs built successfully in 2m 18s | `astra-correction-pass/combined-check.log`, `checks-20261014T120103Z/apks.json` |
| Lint | Zero errors, 23 warnings, two hints | `checks-20261014T120103Z/app/` |
| Android 12 / API 31 | **32/32 passed**, zero failures/skips, 465.936s: 31 UI/lifecycle/widget-receiver cases and one minimum-API URI-decoder case | `astra-correction-pass/native-api31-final.raw.log`, `native-api31-result.json`, screenshots and logcat siblings |
| Android 16 / API 36 | **8/8 passed**, zero failures/skips, 133.683s: recorded HTTP/offline 1, real AppWidgetHost 4, real encrypted-store 3 | `astra-correction-pass/native-api36-final.raw.log`, `native-api36-result.json`, screenshots and logcat siblings |
| Fleet on API 31 | Previously verified 7/7; unchanged fleet source and fixture hashes still match | `offline-handoff/fleet-api31.xml`, source/asset inventories |
| Android 12 no-PIN encryption | **3/3 failed** during real Keystore key generation under the unchanged unlocked-only policy | `offline-handoff/session-api31-first-failures.xml`, source-aligned harness inventory |
| Backend and web | Previously verified 190 passed, one skipped; unchanged by this correction pass | `combined-backend-check.log` |
| Swift contracts | Previously verified 201 core and 32 fleet passed; unchanged by this correction pass | `ios-contract-regression.log` |
| Shared fixtures | Previously verified 2 passed | `native-fixture-after.log` |

The exact combined build command was:

```sh
bash scripts/test-android.sh :app:assembleDebugAndroidTest --continue
```

Native runs used serial-selected `adb shell am instrument -w -r` on the two named dedicated AVDs, with the AndroidJUnitRunner and a parsed count of started/passed/failed/skipped cases. A shell exit of zero or `INSTRUMENTATION_CODE: -1` alone is not treated as acceptance. The HTTP/widget arguments specify `SFN_DEDICATED_AVD`, the recorded fixture at `http://10.0.2.2:8093/subwaysForNerds/api/v1/`, `SFN_TEST_NOW=1788656380` and `SFN_DISABLE_LOCATION=true`. The final E2E worker's exact commands are preserved in `astra-correction-pass/e2e-final-handoff/commands.txt`; the root's raw logs and parsed receipts establish its separate final-source results.

| APK | SHA-256 |
| --- | --- |
| `app-debug.apk` | `940df5b3fe9d0c3b9ca8eab055458911c53b482fadde9d4c3c4d5fdb02f92205` |
| `app-debug-androidTest.apk` | `ef7acc5ab820bd51b38e6b4f1d5c0a27f8014f0b44d28ec6222316738e0eda77` |
| `app-release-unsigned.apk` | `9fa5278c2edda3b01e16c606a88baac707ff8b0f3517a79659e31321e94cdb7c` |

## Corrections and Independent Review

The final read-only Astra `max` review inspected a frozen 324-file coordinator snapshot and verified 1,199 preserved artifact files. All accepted UX files (11), E2E files (3) and E2E dependencies (175) match the final source. No new source-verified defect was found in the bounded correction paths. Report: `astra-correction-pass/independent-final-review/FINAL_REVIEW.md`; source manifest SHA-256: `41e3438de748b1bfbe29cc4f1f0b18c64ee0dc48dee794d7d59031c3d486edb7`.

The five closed findings are:

- Account sync preserves late same-field conflicts, including after owner recreation and a failed follow-up write. The first durable write retains the prior common baseline; advancement follows the conflict decision.
- Unreadable pending sign-in proof remains preserved, with retry and explicitly confirmed replacement. Warm/stale callback handling retains valid proof.
- A second station selection during accepted storage remains the visible and durable selection.
- Widget enable/disable operations are awaited under their sole broadcast owner without blocking the main thread. Update handling transfers to a durably enqueued Glance SessionWorker before scheduling is awaited there; periodic scheduling itself is not claimed to precede update-broadcast completion. Delete and manual refresh await their operations.
- Reconnect cannot start a default-endpoint request before saved settings and offline restoration complete.

Regressions include delayed writes, cancellation, failure propagation and recreated-owner durability. Earlier failing candidates and diagnostics remain preserved. The ride failure was a test click before its control became enabled; readiness was corrected while retaining ride assertions. The HTTP car failure was a self-versus-ancestor scroll-container locator; the corrected test still requires live cars and hides them offline, checks recorded provenance and rejects foreign or successful-after-loss requests.

The separate final-source E2E worker passed 5/5 on its own APK build, with 24 fresh screenshots. The coordinator's final HTTP run recorded 46 successful fixture responses, one refused request after loss, zero foreign-origin requests and zero successful responses after loss. Persisted 58 board rows and the active/manual trips matched the recorded keys and times. This is recorded-service acceptance, not live production transit or physical radio-loss acceptance.

The retained widget image contains the complete source-age label; the earlier qualified clipping observation was not confirmed as a defect. The 200% font capture covers loading/header controls, so loaded departure rows at that font size remain a coverage gap.

## Physical Phone — Initial Debug Build

The USB-authorized Nothing A001 is running Android 15 / API 35. The coordinator installed `nyc.juliet.subwaysfornerds.debug` in place and launched `MainActivity`:

```sh
SFN_ANDROID_SERIAL=00211353Y000327 bash scripts/install-android.sh android/app/build/outputs/apk/debug/app-debug.apk
```

Streamed installation returned `Success`, package-path lookup succeeded and Activity launch returned `Status: ok` with `WaitTime: 3044`. A later read-only SHA-256 of the installed `base.apk` matches the final debug APK. Receipts: `device/install-20261014T122649Z.log`, `astra-correction-pass/physical-install.log` and `physical-installed-byte-readback.json`.

At this initial debug-install checkpoint, the phone was asleep behind keyguard and visible/resumed-app acceptance was pending. The later departure-board performance pass below supersedes that launch limitation for its exact optimized APK. No test APK, fixture injection, uninstall, data reset, radio or permission change was performed on the physical phone. Existing device data, keys and pairings were preserved. Installation, byte readback and a launch request do not establish the remaining manual workflows below.

## Pending Acceptance and Decisions

The Android 12–14 encrypted account-store policy still requires the owner's choice: standard Keystore AES/GCM on older Android while retaining unlocked-device-required keys on Android 15+, or requiring a secure screen lock on older Android. The actual no-PIN failure was measured on API 31; API 32–34 were not tested here. `AndroidSessionStore` still uses `setUnlockedDeviceRequired(true)`, and existing keys/ciphertext have not been replaced. The [Android API guidance](https://developer.android.com/reference/android/security/keystore/KeyGenParameterSpec.Builder#setUnlockedDeviceRequired(boolean)) documents the older-platform issue. Bundled SQLite approval does not resolve this separate security choice.

Manual acceptance remains pending for physical station search, foreground location allowance/denial, background GPS, offline relaunch after actual radio loss, saved rides, fleet download/update/cancel, home-widget placement/resize/refresh, deep links and retained data. OEM lock-screen widget support is device-dependent. TalkBack spoken output, loaded-row 200% font behavior and a large production fleet download remain unverified.

Warm/cold callback tests exercise native Activity/manifest routing with injected account services and vaults. Real encrypted storage is tested separately on API 36. Live OAuth and encrypted browser recovery after process death remain unverified; Activity recreation and reopening in the same instrumentation process do not prove killed-process recovery.

## Ownership and Cleanup

The correction workers have settled: UX and independent review terminals were released; the E2E terminal is retained as user-owned. Every worktree and verification artifact is preserved. The coordinator owns cleanup of the task-created `sfn-android31-native` and `sfn-android36-native` AVDs and its recorded fixture on `127.0.0.1:8093`. Cleanup status is recorded in `artifacts/android/final-checkpoint.json`; the unrelated iOS fixture and physical phone are excluded.

The earlier quota-interrupted source cuts, startup timeout, native failures, red regressions and intermediate builds remain in `artifacts/android/`. Final receipts supersede those checkpoints only for their stated source and test scope. No remote CI run is claimed.

## Departure Board Scroll Performance — October 14, 2026

This addendum covers the requested departure-board scrolling correction. It supersedes the earlier app-JVM count, debug-only phone state and APK-delivery choice for this change; the earlier API 31/API 36 instrumentation results remain evidence for their preceding source cut. No new emulator instrumentation was executed for this performance pass.

`AppModel` now retains structurally equal catalog, favorite, page, visibility-filtered board and grouped-departure results. Core grouping still evaluates time-dependent membership on clock changes: one-second countdowns, exact live/stale boundaries and stale-row reappearance are preserved. A one-pass predecessor table replaces repeated prefix scans in departure rows while retaining direction, boarding origin, effective track and boardability rules. Layout, row keys, controls, filters and source-age labels were preserved.

The `optimized` variant is nondebuggable and enables R8/resource shrinking with `BuildConfig.DEBUG=false`. It uses the installed debug application ID and existing debug signing key for an in-place update; production release signing is unchanged. No dependency was added or upgraded in this pass.

### Automated Checks and Shrinker Correction

The implementation worker ran the regression tests before implementation: two expected identity-reuse failures established the missing behavior. After correction, 19 focused tests passed. An intermediate combined-station test timed out during setup; selecting the combined station before activation under its fixed clock removed the setup race without weakening assertions. The subsequent fresh full app-JVM run passed **138/138**, with zero failures, errors or skips. The coordinator independently parsed the XML and matched all 185 root/worker source inputs for that execution; this was not a second coordinator test run. Core/fleet tests were not rerun for this count.

The implementation command was:

```sh
source scripts/android-env.sh
./android/gradlew -p android --offline --console=plain :app:testDebugUnitTest :app:compileOptimizedKotlin :app:assembleOptimized :app:assembleDebug
```

The first optimized APK built successfully but failed physical startup because R8 stripped the reflective `WorkDatabase_Impl` constructor. Independent actual-DEX review also found the Glance `RefreshWidgetAction` constructor and `onAction` implementation stripped. Narrow keep rules repaired both contracts. The first artifact (`f4a9441866cd5d811a0bb9d35476c138ea0ce2adc378d549767c26b9491bceb2`) is retained for negative checks and must not be distributed. Its foreground guard rejected measurement before swipes; a delayed launch result after restoring working debug is excluded from optimized-launch evidence.

The corrected `:app:assembleOptimized` rebuild passed in 6m 51s. `scripts/check-android-apk.sh` failed both missing public constructors on the known-bad APK and passed both on the corrected APK. Independent DEX inspection additionally verified the retained public nonempty `onAction` implementation and inspected 31 manifest/startup/worker entry-point classes. The script guards the two constructors only; it does not replace physical widget-action acceptance. The default validation wrapper now builds optimized and propagates that binary check's failure. The entire wrapper was not rerun after this narrow integration; shell syntax and the direct negative/positive checks passed.

The coordinator compiled the debug and instrumentation APKs on the integrated source. The initial broad lint invocation was deliberately cancelled (exit 130) to prioritize the shrinker correction, then this exact check resumed and passed in 4m 40s:

```sh
source scripts/android-env.sh
./android/gradlew -p android --offline --console=plain :app:lintDebug
bash -n scripts/test-android.sh scripts/check-android-apk.sh
bash scripts/check-android-apk.sh artifacts/android/scroll-performance/optimized-v2/app-optimized.apk
```

Lint reported zero errors/fatals, 23 warnings and two hints. The first R8 build also emitted a nonfatal stack-trace-tokenization warning for `WidgetPreview`; its original log is retained. Evidence is under `scroll-performance/verified-worker-units/`, `implementation-handoff/`, `room-fix-handoff/`, `root-build-lint-first-interrupted.log` and `root-lint-resumed.log`.

### Physical Installation and Repeated Scrolling

The final APK is `scroll-performance/optimized-v2/app-optimized.apk`, **9,970,781 bytes**, SHA-256 **`7e68d379286a60fdbad41b2621a8a4a0e74c3cff5066929e2efb920d8d5a3d1d`**. Its signing-certificate SHA-256 is `da230f0071bba4ec6382ef3d3268a74ba51a8da370dde4c8ce0c700400bef985`, matching the previous installation. It targets Android 12/API 31 and later. The existing private [APK download](https://drive.google.com/file/d/1KlCdw_fyTlVRhlGBWlIWeSLXTOTIPxsu/view?usp=drivesdk) was replaced in place with this file as `Subways-for-Nerds-0.1.0-optimized.apk`; Drive metadata confirms the expected size and owner-only permissions. The connector did not expose a provider-side checksum; the SHA above is from the local verified upload input.

The USB-authorized Nothing A001 on Android 15/API 35 received an in-place install, preserving package data and keys:

```sh
SFN_ANDROID_SERIAL=00211353Y000327 bash scripts/install-android.sh artifacts/android/scroll-performance/optimized-v2/app-optimized.apk
python3 artifacts/android/scroll-performance/measure-phone.py optimized-v2 7e68d379286a60fdbad41b2621a8a4a0e74c3cff5066929e2efb920d8d5a3d1d
```

The completed install returned success and WARM launch time 729 ms. The measurement guard verified an awake, unlocked phone, actually resumed `MainActivity` and the exact installed APK SHA before sending swipes. Post-run byte/foreground checks matched; the bounded current-PID log contained no FATAL/ANR match. Settings-to-Board navigation and a separate cold launch (495 ms) succeeded without preference changes. This is actual foreground/navigation evidence, not complete manual acceptance.

Each artifact received one unmeasured down/up warmup pair followed by three runs of four down/up pairs, with a fresh `gfxinfo` reset per run. Swipes used the same coordinates and 450 ms duration, with a one-second tail. Raw counter output, screenshots and the script are retained alongside `scroll-performance/comparison.json`.

| Installed artifact | Janky frames / total | Aggregate jank | P95 frame time by run |
| --- | --- | --- | --- |
| Original debug | 223 / 1,107 | 20.14% | 32 / 31 / 30 ms |
| Corrected source, debug | 223 / 907 | 24.59% | 53 / 42 / 36 ms |
| Corrected optimized | 48 / 1,389 | 3.46% | 15 / 15 / 16 ms |

The optimized artifact improved the observed frame-deadline and P95 results in all three runs compared with the original debug. These are repeated inputs on a live production board on one phone. Data, clock, thermal state and compilation warmup were uncontrolled; the corrected-debug first run followed installation while the original was already warm. The debug comparison does **not** demonstrate an isolated source-only speedup, and the optimized result combines source work with build-mode changes. The older mixed-use 646-frame counter is not the baseline.

### Independent Review and Remaining Limits

GPT-6 Astra at max effort reviewed a frozen 187-file source/script cut, the tests, actual packaged DEX, raw frame outputs, lint and runtime receipts. Every Android/build/script path matched the implementation worker; only the coordinator-owned implementation document differed. The review found no unresolved correctness blocker in this bounded correction. The report and immutable evidence are copied under `scroll-performance/independent-review/`.

A screenshot-preview concern about missing app bars was disproved by independent decoded-PNG comparison: the complete top and bottom app-bar regions were byte-identical between baseline and optimized screenshots, including the cold launch. Navigation and UI hierarchy agreed. The unnecessary control-build diagnostic was cancelled; no diagnostic APK was installed or distributed.

No new API 31, physical home-widget placement/refresh, TalkBack, live OAuth, process-death encrypted recovery, radio-loss, large-fleet or 200% loaded-row acceptance is claimed. The older Android 12–14 Keystore policy choice remains pending and unchanged. All worktrees and artifacts are preserved. After accepted settlement, the review terminal was released; the release request retained the reused implementation terminal as external, with no reclaimable worker terminal remaining. No commit, push, PR or deployment was made.
