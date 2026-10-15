#!/usr/bin/env bash
set -euo pipefail

sfn_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$sfn_repo_root/scripts/android-env.sh"
cd "$sfn_repo_root"
sfn_apk="${1:-android/app/build/outputs/apk/optimized/app-optimized.apk}"
sfn_analyzer="${ANDROID_HOME:-}/cmdline-tools/latest/bin/apkanalyzer"

if [[ ! -x "$sfn_analyzer" ]]; then
	printf '%s\n' 'Android SDK apkanalyzer is required. Set ANDROID_HOME or see docs/android.md.' >&2
	exit 1
fi
if [[ ! -f "$sfn_apk" ]]; then
	printf 'APK not found: %s\n' "$sfn_apk" >&2
	exit 1
fi

printf 'Checking packaged reflection constructors: %s\n' "$sfn_apk"
sfn_failures=0
for sfn_class in \
	androidx.work.impl.WorkDatabase_Impl \
	nyc.juliet.subwaysfornerds.widgets.ui.RefreshWidgetAction; do
	if sfn_constructor_output="$("$sfn_analyzer" dex code --class "$sfn_class" --method '<init>()V' "$sfn_apk" 2>&1)" &&
		awk '
			/^[ \t]*\.method[ \t]+/ && /(^|[ \t])public([ \t]|$)/ &&
			/(^|[ \t])constructor([ \t]|$)/ && /[ \t]<init>\(\)V([ \t]|$)/ { found = 1 }
			END { exit !found }
		' <<< "$sfn_constructor_output"; then
		printf 'PASS %s public <init>()V\n' "$sfn_class"
	else
		printf 'FAIL %s is missing a packaged public zero-argument constructor\n' "$sfn_class" >&2
		printf '%s\n' "$sfn_constructor_output" >&2
		sfn_failures=$((sfn_failures + 1))
	fi
done

if [[ "$sfn_failures" -ne 0 ]]; then
	printf 'APK reflection checks failed: %s\n' "$sfn_failures" >&2
	exit 1
fi
