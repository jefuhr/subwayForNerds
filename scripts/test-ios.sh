#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Xcode.app/Contents/Developer && -z ${DEVELOPER_DIR:-} ]]; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodebuild -version
mkdir -p artifacts
simulator_id=${SFN_SIMULATOR_ID:-$(xcrun simctl list devices available --json | node --input-type=module -e '
let text = "";
for await (const chunk of process.stdin) text += chunk;
const choices = Object.entries(JSON.parse(text).devices)
	.filter(([runtime]) => /iOS-(?:2[6-9]|[3-9][0-9])/.test(runtime))
	.flatMap(([, devices]) => devices).filter(d => d.isAvailable && d.name.includes("iPhone"));
const device = choices.find(d => d.state === "Booted") || choices[0];
if (!device) { console.error("Install an iOS 26+ iPhone simulator in Xcode Settings > Components."); process.exit(1); }
process.stdout.write(device.udid);
')}
if curl -fsS --max-time 1 http://127.0.0.1:8092/healthz >/dev/null 2>&1; then
	echo 'Port 8092 is already in use. Stop the existing fixture server before running native UI tests.' >&2
	exit 1
fi
node_modules/.bin/tsx test/fixture-server.ts > artifacts/native-fixture-server.log 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true' EXIT
ready=false
for ((attempt=0; attempt<60; attempt++)); do
	kill -0 "$fixture_pid" 2>/dev/null || { cat artifacts/native-fixture-server.log; exit 1; }
	if curl -fsS --max-time 1 http://127.0.0.1:8092/subwaysForNerds/api/v1/fleet/offline/manifest >/dev/null; then ready=true; break; fi
	sleep 1
done
[[ "$ready" == true ]] || { echo 'Fixture server did not start.' >&2; exit 1; }
result="artifacts/native-ui-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild test -project ios/SubwaysForNerds.xcodeproj -scheme SubwaysForNerds \
	-destination "platform=iOS Simulator,id=$simulator_id" -destination-timeout 120 \
	-resultBundlePath "$result" -collect-test-diagnostics never \
	-derivedDataPath ios/DerivedData/Simulator -jobs "${SFN_BUILD_JOBS:-2}" CODE_SIGNING_ALLOWED=NO 2>&1 | tee artifacts/native-ui-tests.log
