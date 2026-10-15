#!/usr/bin/env bash
set -euo pipefail

sfn_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$sfn_repo_root/scripts/android-env.sh"
cd "$sfn_repo_root"
sfn_apk="${1:-android/app/build/outputs/apk/debug/app-debug.apk}"
sfn_device="${SFN_ANDROID_SERIAL:-}"

if ! command -v adb >/dev/null; then
	printf '%s\n' 'Android platform-tools are required. See docs/android.md.' >&2
	exit 1
fi
if [[ ! -f "$sfn_apk" ]]; then
	printf 'APK not found: %s\n' "$sfn_apk" >&2
	exit 1
fi
if [[ -z "$sfn_device" ]]; then
	sfn_devices="$(adb devices | awk '$1 !~ /^emulator-/ && $2 == "device" { print $1 }')"
	sfn_count="$(printf '%s\n' "$sfn_devices" | awk 'NF { count++ } END { print count+0 }')"
	if [[ "$sfn_count" != 1 ]]; then
		printf '%s\n' 'Connect and authorize one Android phone, or set SFN_ANDROID_SERIAL explicitly.' >&2
		adb devices -l
		exit 1
	fi
	sfn_device="$sfn_devices"
fi
if [[ "$(adb -s "$sfn_device" get-state)" != device ]]; then
	printf '%s\n' 'Accept the USB debugging prompt on the selected device first.' >&2
	exit 1
fi
sfn_api="$(adb -s "$sfn_device" shell getprop ro.build.version.sdk | tr -d '\r')"
if [[ ! "$sfn_api" =~ ^[0-9]+$ || "$sfn_api" -lt 31 ]]; then
	printf '%s\n' 'This app requires Android 12 (API 31) or newer.' >&2
	exit 1
fi
sfn_package="$("$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer" manifest application-id "$sfn_apk")"
if [[ "$sfn_package" != nyc.juliet.subwaysfornerds && "$sfn_package" != nyc.juliet.subwaysfornerds.debug ]]; then
	printf 'Unexpected APK package: %s\n' "$sfn_package" >&2
	exit 1
fi
mkdir -p artifacts/android/device
sfn_receipt="artifacts/android/device/install-$(date -u +%Y%m%dT%H%M%SZ).log"
{
	printf 'Package: %s\n' "$sfn_package"
	printf 'Model: '
	adb -s "$sfn_device" shell getprop ro.product.model
	printf 'Android: '
	adb -s "$sfn_device" shell getprop ro.build.version.release
	shasum -a 256 "$sfn_apk"
	adb -s "$sfn_device" install -r "$sfn_apk"
	adb -s "$sfn_device" shell pm path "$sfn_package"
	adb -s "$sfn_device" shell am start -W -n "$sfn_package/nyc.juliet.subwaysfornerds.MainActivity"
} 2>&1 | tee "$sfn_receipt"
printf 'Install and launch receipt: %s\n' "$sfn_receipt"
printf '%s\n' 'Installation does not establish physical acceptance. Verify widgets, location, offline use, and retained data on the phone.'
