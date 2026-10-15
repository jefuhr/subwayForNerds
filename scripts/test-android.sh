#!/usr/bin/env bash
set -euo pipefail

sfn_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$sfn_repo_root/scripts/android-env.sh"
cd "$sfn_repo_root"
sfn_result_dir="artifacts/android/checks-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$sfn_result_dir"

if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
	printf '%s\n' 'JDK 17 is required. Set JAVA_HOME or follow docs/android.md.' >&2
	exit 1
fi
if [[ -z "${ANDROID_HOME:-}" || ! -d "$ANDROID_HOME/platforms/android-37.0" ]]; then
	printf '%s\n' 'Android SDK platform 37.0 is required. Set ANDROID_HOME or follow docs/android.md.' >&2
	exit 1
fi

set +e
./android/gradlew -p android --console=plain \
	:transit-core:test :fleet-offline:testDebugUnitTest :app:testDebugUnitTest \
	:app:lintDebug :app:assembleDebug :app:assembleRelease :app:assembleOptimized "$@" \
	2>&1 | tee "$sfn_result_dir/gradle.log"
sfn_gradle_status=${PIPESTATUS[0]}
set -e

sfn_validation_status="$sfn_gradle_status"
if [[ "$sfn_gradle_status" -eq 0 ]]; then
	set +e
	bash scripts/check-android-apk.sh android/app/build/outputs/apk/optimized/app-optimized.apk \
		2>&1 | tee "$sfn_result_dir/apk-reflection.log"
	sfn_validation_status=${PIPESTATUS[0]}
	set -e
fi

python3 - "$sfn_result_dir" <<'PY'
from pathlib import Path
import hashlib, json, shutil, sys
out = Path(sys.argv[1])
artifacts = []
for module in ['app', 'transit-core', 'fleet-offline']:
    reports = Path('android') / module / 'build/reports'
    if reports.is_dir():
        shutil.copytree(reports, out / module, dirs_exist_ok=True)
for apk in Path('android/app/build/outputs/apk').rglob('*.apk'):
    artifacts.append({'path': str(apk), 'bytes': apk.stat().st_size,
                      'sha256': hashlib.sha256(apk.read_bytes()).hexdigest()})
(out / 'apks.json').write_text(json.dumps(artifacts, indent=2) + '\n')
print('Android reports:', out)
for artifact in artifacts:
    print(artifact['path'], artifact['sha256'])
PY
exit "$sfn_validation_status"
