#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -d /Applications/Xcode.app/Contents/Developer && -z ${DEVELOPER_DIR:-} ]]; then
	export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
mkdir -p artifacts
native_args=(--disable-xctest)
swift_binary=$(xcrun --find swiftc)
toolchain_usr=$(dirname "$(dirname "$swift_binary")")
# Current command-line tools ship Swift Testing's macro separately from swiftbuild's defaults.
testing_macro="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$testing_macro" ]]; then
	native_args+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_macro")
fi
for package in TransitCore FleetOffline; do
	swift test --jobs "${SFN_BUILD_JOBS:-2}" --package-path "ios/$package" "${native_args[@]}" 2>&1 | tee "artifacts/$package-tests.log"
done
