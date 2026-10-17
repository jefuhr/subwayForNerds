#!/usr/bin/env bash
set -euo pipefail

: "${SFN_ANDROID_SERIAL:?Select a dedicated emulator with SFN_ANDROID_SERIAL}"
: "${SFN_ANDROID_DEDICATED_AVD:?Name that dedicated emulator with SFN_ANDROID_DEDICATED_AVD}"
export SFN_ANDROID_FIXTURE_PORT="${SFN_ANDROID_FIXTURE_PORT:-8194}"
export FIXTURE_TRACK_MAP=1

# Reuse the recorded-HTTP runner's device checks, isolated fixture and evidence collection.
exec bash "$(dirname "$0")/test-android-e2e.sh" \
	-x :fleet-offline:connectedDebugAndroidTest \
	-Pandroid.testInstrumentationRunnerArguments.class=nyc.juliet.subwaysfornerds.TrackMapE2ETest \
	--max-workers=2 "$@"
