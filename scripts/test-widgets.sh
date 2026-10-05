#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SFN_SIMULATOR_ID=${SFN_SIMULATOR_ID:-$(xcrun simctl list devices available --json | node --input-type=module -e '
let input = "";
for await (const chunk of process.stdin) input += chunk;
const devices = Object.values(JSON.parse(input).devices).flat().filter(d => d.isAvailable && d.name.includes("iPhone"));
const selected = devices.find(d => d.state === "Booted") || devices[0];
if (!selected) { console.error("Install an iPhone simulator in Xcode."); process.exit(1); }
process.stdout.write(selected.udid);
')}
fixture_port=${SFN_FIXTURE_PORT:-8092}
mkdir -p artifacts/widgets
if curl -fsS --max-time 1 "http://127.0.0.1:$fixture_port/healthz" >/dev/null 2>&1; then
	echo 'Port 8092 is already in use.' >&2; exit 1
fi
FIXTURE_PORT=$fixture_port node_modules/.bin/tsx test/fixture-server.ts > artifacts/widgets/fixture-server.log 2>&1 &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true' EXIT
for ((attempt=0; attempt<60; attempt++)); do
	kill -0 "$fixture_pid" 2>/dev/null || exit 1
	if curl -fsS --max-time 1 "http://127.0.0.1:$fixture_port/healthz" >/dev/null 2>&1; then break; fi
	sleep 1
done
result="artifacts/widgets/ui-$(date +%Y%m%d-%H%M%S).xcresult"
TEST_RUNNER_SFN_WIDGET_QA_API="http://127.0.0.1:$fixture_port/subwaysForNerds/api/v1/" xcodebuild test -project ios/SubwaysForNerds.xcodeproj -scheme SubwaysForNerds \
	-destination "platform=iOS Simulator,id=$SFN_SIMULATOR_ID" \
	-derivedDataPath ios/DerivedData/Widgets -resultBundlePath "$result" -collect-test-diagnostics never \
	-only-testing:SubwaysForNerdsUITests/SubwaysForNerdsUITests/testWidgetDisplaySettingsHideInformationAndSurviveRelaunch \
	-only-testing:SubwaysForNerdsUITests/SubwaysForNerdsUITests/testWidgetSettingsPreserveIndependentFiltersAcrossToggleAndRelaunch \
	-only-testing:SubwaysForNerdsUITests/SubwaysForNerdsUITests/testEveryWidgetFamilyAndFailureStateRenders \
	-only-testing:SubwaysForNerdsUITests/SubwaysForNerdsUITests/testWidgetDeepLinkWinsOverClosestFavoriteStartup \
	CODE_SIGNING_ALLOWED=NO > artifacts/widgets/ui-latest.log 2>&1
xcrun xcresulttool export attachments --path "$result" --output-path "${result%.xcresult}-screens"
