#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
: "${SFN_SIMULATOR_ID:?Select a dedicated track-map test simulator with SFN_SIMULATOR_ID}"
sfn_fixture_port=${SFN_FIXTURE_PORT:-8192}
sfn_result_dir="artifacts/track-map/ios-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$sfn_result_dir"
python3 - "$sfn_fixture_port" <<'PY'
import socket, sys
with socket.socket() as listener:
	listener.bind(('127.0.0.1', int(sys.argv[1])))
PY
xcrun simctl bootstatus "$SFN_SIMULATOR_ID" -b
SFN_AUTH_ENABLED=false FIXTURE_TRACK_MAP=1 FIXTURE_PORT="$sfn_fixture_port" node_modules/.bin/tsx test/fixture-server.ts > "$sfn_result_dir/fixture.log" 2>&1 &
sfn_fixture_pid=$!
sfn_cleanup() {
	kill "$sfn_fixture_pid" 2>/dev/null || true
	wait "$sfn_fixture_pid" 2>/dev/null || true
	if [[ -d "$sfn_result_dir/tests.xcresult" ]]; then
		xcrun xcresulttool export attachments --path "$sfn_result_dir/tests.xcresult" --output-path "$sfn_result_dir/screenshots" \
			> "$sfn_result_dir/attachment-export.log" 2>&1 || true
	fi
	printf 'Track-map iOS artifacts: %s\n' "$sfn_result_dir"
}
trap sfn_cleanup EXIT
sfn_ready=false
for ((sfn_attempt=0; sfn_attempt<60; sfn_attempt++)); do
	kill -0 "$sfn_fixture_pid" 2>/dev/null || { cat "$sfn_result_dir/fixture.log"; exit 1; }
	if curl -fsS --max-time 1 "http://127.0.0.1:$sfn_fixture_port/subwaysForNerds/api/v1/track-map/nyc-2.6.8-v1/snapshot" > "$sfn_result_dir/snapshot.json"; then sfn_ready=true; break; fi
	sleep 1
done
[[ "$sfn_ready" == true ]] || { echo 'Track-map fixture did not become ready.' >&2; exit 1; }
TEST_RUNNER_SFN_WIDGET_QA_API="http://127.0.0.1:$sfn_fixture_port/subwaysForNerds/api/v1/" \
	xcodebuild test -project ios/SubwaysForNerds.xcodeproj -scheme SubwaysForNerds \
	-destination "platform=iOS Simulator,id=$SFN_SIMULATOR_ID" -destination-timeout 120 \
	-derivedDataPath ios/DerivedData/TrackMap -resultBundlePath "$sfn_result_dir/tests.xcresult" \
	-jobs "${SFN_BUILD_JOBS:-2}" -parallel-testing-enabled NO -collect-test-diagnostics never \
	-only-testing:SubwaysForNerdsUITests/TrackMapUITests CODE_SIGNING_ALLOWED=NO "$@" \
	2>&1 | tee "$sfn_result_dir/xcodebuild.log"
