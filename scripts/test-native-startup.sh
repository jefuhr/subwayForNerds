#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
sfn_output="$PWD/artifacts/native-startup"
mkdir -p "$sfn_output/modules" "$sfn_output/cache"
sfn_sdk=$(xcrun --sdk macosx --show-sdk-path)
sfn_swiftc=$(xcrun --find swiftc)
sfn_common=(-disable-sandbox -swift-version 6 -strict-concurrency=complete -target "$(uname -m)-apple-macos14.0" -sdk "$sfn_sdk" -module-cache-path "$sfn_output/cache" -I "$sfn_output/modules")
"$sfn_swiftc" "${sfn_common[@]}" -parse-as-library -module-name TransitCore -emit-library -emit-module -emit-module-path "$sfn_output/modules/TransitCore.swiftmodule" ios/TransitCore/Sources/TransitCore/*.swift -o "$sfn_output/libTransitCore.dylib"
"$sfn_swiftc" "${sfn_common[@]}" -parse-as-library -module-name FleetOffline -emit-library -emit-module -emit-module-path "$sfn_output/modules/FleetOffline.swiftmodule" -I ios/FleetOffline/Sources/CSQLite ios/FleetOffline/Sources/FleetOffline/*.swift -L "$sfn_output" -lTransitCore -lsqlite3 -lz -o "$sfn_output/libFleetOffline.dylib"
"$sfn_swiftc" "${sfn_common[@]}" -parse-as-library -D DEBUG -I ios/FleetOffline/Sources/CSQLite ios/SubwaysForNerds/App/AppModel.swift test/native-startup.swift -L "$sfn_output" -lTransitCore -lFleetOffline -Xlinker -rpath -Xlinker "$sfn_output" -o "$sfn_output/startup-tests"
"$sfn_output/startup-tests"
