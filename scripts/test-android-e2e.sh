#!/usr/bin/env bash
set -euo pipefail

sfn_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$sfn_repo_root/scripts/android-env.sh"
cd "$sfn_repo_root"
sfn_api_port="${SFN_ANDROID_FIXTURE_PORT:-8093}"
sfn_result_dir="artifacts/android/e2e-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$sfn_result_dir"

if ! command -v adb >/dev/null; then
	printf '%s\n' 'Android platform-tools are required. See docs/android.md.' >&2
	exit 1
fi
sfn_device="${SFN_ANDROID_SERIAL:-}"
if [[ "$sfn_device" != emulator-* ]]; then
	printf '%s\n' 'Use a dedicated emulator for fixture tests via SFN_ANDROID_SERIAL. Physical device data is never reset by this runner.' >&2
	exit 1
fi
sfn_avd="$(adb -s "$sfn_device" shell getprop ro.boot.qemu.avd_name | tr -d '\r')"
if [[ -z "$sfn_avd" ]]; then
	sfn_avd="$(adb -s "$sfn_device" shell getprop ro.kernel.qemu.avd_name | tr -d '\r')"
fi
sfn_expected_avd="${SFN_ANDROID_DEDICATED_AVD:-}"
if [[ -z "$sfn_expected_avd" ]]; then
	case "$sfn_avd" in
		sfn-android31-native|sfn-android36-native) sfn_expected_avd="$sfn_avd" ;;
		*) printf '%s\n' 'Select a dedicated test AVD with SFN_ANDROID_DEDICATED_AVD. Fixture tests reset this app on that emulator.' >&2; exit 1 ;;
	esac
fi
if [[ "$sfn_avd" != "$sfn_expected_avd" ]]; then
	printf 'Selected AVD %s differs from the dedicated test AVD %s.\n' "$sfn_avd" "$sfn_expected_avd" >&2
	exit 1
fi
if [[ "$(adb -s "$sfn_device" get-state)" != device ]]; then
	printf '%s\n' 'The selected emulator is unavailable.' >&2
	exit 1
fi
python3 - "$sfn_api_port" <<'PY'
import socket, sys
with socket.socket() as listener:
    listener.bind(('127.0.0.1', int(sys.argv[1])))
PY

sfn_fixture_pid=""
sfn_cleanup() {
	if [[ -n "$sfn_fixture_pid" ]] && kill -0 "$sfn_fixture_pid" 2>/dev/null; then
		kill "$sfn_fixture_pid"
		wait "$sfn_fixture_pid" 2>/dev/null || true
	fi
	adb -s "$sfn_device" logcat -d -v threadtime > "$sfn_result_dir/logcat.txt" 2>/dev/null || true
	adb -s "$sfn_device" pull /sdcard/Android/data/nyc.juliet.subwaysfornerds.debug/files/screenshots \
		"$sfn_result_dir/screenshots" > "$sfn_result_dir/screenshot-pull.log" 2>&1 || true
	for sfn_module in app fleet-offline; do
		if [[ -d "android/$sfn_module/build/reports/androidTests" ]]; then
			cp -R "android/$sfn_module/build/reports/androidTests" "$sfn_result_dir/$sfn_module-reports"
		fi
		if [[ -d "android/$sfn_module/build/outputs/androidTest-results" ]]; then
			cp -R "android/$sfn_module/build/outputs/androidTest-results" "$sfn_result_dir/$sfn_module-results"
		fi
	done
}
trap sfn_cleanup EXIT INT TERM

SFN_AUTH_ENABLED=false FIXTURE_PORT="$sfn_api_port" FIXTURE_NJT=1 \
	node --import tsx test/fixture-server.ts > "$sfn_result_dir/fixture-server.log" 2>&1 &
sfn_fixture_pid=$!
for sfn_attempt in {1..60}; do
	if curl --silent --fail "http://127.0.0.1:$sfn_api_port/subwaysForNerds/api/v1/stations" > /dev/null; then
		break
	fi
	if ! kill -0 "$sfn_fixture_pid" 2>/dev/null; then
		cat "$sfn_result_dir/fixture-server.log" >&2
		exit 1
	fi
	sleep 1
done
curl --silent --fail "http://127.0.0.1:$sfn_api_port/subwaysForNerds/api/v1/health" > "$sfn_result_dir/fixture-health.json"
sfn_fixture_now="$(node --import tsx --input-type=module -e "import { fixtureNow } from './test/fixture-service.ts'; process.stdout.write(String(fixtureNow));")"
export ANDROID_SERIAL="$sfn_device"

./android/gradlew -p android --console=plain \
	:app:connectedDebugAndroidTest :fleet-offline:connectedDebugAndroidTest \
	-Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true \
	"-Pandroid.testInstrumentationRunnerArguments.SFN_DEDICATED_AVD=$sfn_expected_avd" \
	"-Pandroid.testInstrumentationRunnerArguments.SFN_API_BASE_URL=http://10.0.2.2:$sfn_api_port/subwaysForNerds/api/v1/" \
	"-Pandroid.testInstrumentationRunnerArguments.SFN_TEST_NOW=$sfn_fixture_now" \
	"-Pandroid.testInstrumentationRunnerArguments.SFN_DISABLE_LOCATION=true" \
	"-Pandroid.testInstrumentationRunnerArguments.SFN_ARTIFACT_DIR=$sfn_result_dir" \
	"$@" 2>&1 | tee "$sfn_result_dir/gradle.log"

adb -s "$sfn_device" exec-out screencap -p > "$sfn_result_dir/final-screen.png"
printf 'Android E2E artifacts: %s\n' "$sfn_result_dir"
