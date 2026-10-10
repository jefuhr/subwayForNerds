#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
sfn_output="$PWD/artifacts/native-account-choices"
mkdir -p "$sfn_output/modules" "$sfn_output/cache"
sfn_sdk=$(xcrun --sdk macosx --show-sdk-path)
sfn_swiftc=$(xcrun --find swiftc)
sfn_common=(-disable-sandbox -swift-version 6 -strict-concurrency=complete -target "$(uname -m)-apple-macos14.0" -sdk "$sfn_sdk" -module-cache-path "$sfn_output/cache" -I "$sfn_output/modules")
"$sfn_swiftc" "${sfn_common[@]}" -parse-as-library -module-name TransitCore -emit-library -emit-module -emit-module-path "$sfn_output/modules/TransitCore.swiftmodule" ios/TransitCore/Sources/TransitCore/*.swift -o "$sfn_output/libTransitCore.dylib"
"$sfn_swiftc" "${sfn_common[@]}" -parse-as-library ios/SubwaysForNerds/Views/AccountConflictChoices.swift test/native-account-choices.swift -L "$sfn_output" -lTransitCore -Xlinker -rpath -Xlinker "$sfn_output" -o "$sfn_output/choices-tests"
"$sfn_output/choices-tests"
