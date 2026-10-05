#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${DOOR_NATIVE_NAVIGATION_ONLY:-false}" = true ]; then
    for flag in "${DOOR_NATIVE_PERSONAL_ONLY:-false}" "${DOOR_NATIVE_ROUTE_TOOLS_ONLY:-false}" "${DOOR_NATIVE_ROUTE_ONLY:-false}" "${DOOR_NATIVE_MINI_ONLY:-false}" "${DOOR_NATIVE_RIDING_ONLY:-false}" "${DOOR_NATIVE_CAMERA_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_SURFACE_ONLY:-false}" "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" "${DOOR_NATIVE_DENSE_UI_ONLY:-false}" "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" "${DOOR_UI_EVIDENCE_ONLY:-false}"; do
        if [ "$flag" = true ]; then echo "Choose one isolated native test phase"; exit 2; fi
    done
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-navigation.sh"
fi
if [ "${DOOR_NATIVE_PERSONAL_ONLY:-false}" = true ]; then
    for flag in "${DOOR_NATIVE_ROUTE_TOOLS_ONLY:-false}" "${DOOR_NATIVE_ROUTE_ONLY:-false}" "${DOOR_NATIVE_MINI_ONLY:-false}" "${DOOR_NATIVE_RIDING_ONLY:-false}" "${DOOR_NATIVE_CAMERA_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_SURFACE_ONLY:-false}" "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" "${DOOR_NATIVE_DENSE_UI_ONLY:-false}" "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" "${DOOR_UI_EVIDENCE_ONLY:-false}"; do
        if [ "$flag" = true ]; then echo "Choose one isolated native test phase"; exit 2; fi
    done
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-personal.sh"
fi
if [ "${DOOR_NATIVE_ROUTE_TOOLS_ONLY:-false}" = true ]; then
    for flag in "${DOOR_NATIVE_ROUTE_ONLY:-false}" "${DOOR_NATIVE_MINI_ONLY:-false}" "${DOOR_NATIVE_RIDING_ONLY:-false}" "${DOOR_NATIVE_CAMERA_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_SURFACE_ONLY:-false}" "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" "${DOOR_NATIVE_DENSE_UI_ONLY:-false}" "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" "${DOOR_UI_EVIDENCE_ONLY:-false}"; do
        if [ "$flag" = true ]; then echo "Choose one isolated native test phase"; exit 2; fi
    done
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-route-tools.sh"
fi
if [ "${DOOR_NATIVE_ROUTE_ONLY:-false}" = true ]; then
    for flag in "${DOOR_NATIVE_MINI_ONLY:-false}" "${DOOR_NATIVE_RIDING_ONLY:-false}" "${DOOR_NATIVE_CAMERA_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_SURFACE_ONLY:-false}" "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" "${DOOR_NATIVE_DENSE_UI_ONLY:-false}" "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" "${DOOR_UI_EVIDENCE_ONLY:-false}"; do
        if [ "$flag" = true ]; then echo "Choose one isolated native test phase"; exit 2; fi
    done
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-route.sh"
fi
if [ "${DOOR_NATIVE_MINI_ONLY:-false}" = true ]; then
    for flag in "${DOOR_NATIVE_RIDING_ONLY:-false}" "${DOOR_NATIVE_CAMERA_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_SURFACE_ONLY:-false}" "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" "${DOOR_NATIVE_DENSE_UI_ONLY:-false}" "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" "${DOOR_UI_EVIDENCE_ONLY:-false}"; do
        if [ "$flag" = true ]; then echo "Choose one isolated native test phase"; exit 2; fi
    done
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-mini.sh"
fi
if [ "${DOOR_NATIVE_RIDING_ONLY:-false}" = true ]; then
    for flag in "${DOOR_NATIVE_CAMERA_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" "${DOOR_NATIVE_SURFACE_ONLY:-false}" "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" "${DOOR_NATIVE_DENSE_UI_ONLY:-false}" "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" "${DOOR_UI_EVIDENCE_ONLY:-false}"; do
        if [ "$flag" = true ]; then echo "Choose one isolated native test phase"; exit 2; fi
    done
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-riding.sh"
fi
if [ "${DOOR_NATIVE_CAMERA_FOUNDATION_ONLY:-false}" = true ]; then
    if [ "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" = true ] || [ "${DOOR_NATIVE_SURFACE_ONLY:-false}" = true ] || [ "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" = true ] || [ "${DOOR_NATIVE_DENSE_UI_ONLY:-false}" = true ] || [ "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" = true ] || [ "${DOOR_UI_EVIDENCE_ONLY:-false}" = true ]; then
        echo "Choose one isolated native test phase"; exit 2
    fi
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-camera-foundation.sh"
fi
if [ "${DOOR_NATIVE_DENSE_UI_ONLY:-false}" = true ] && [ "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" != true ]; then
    echo "Dense UI mode requires the isolated repair workflow"; exit 2
fi
if [ "${DOOR_NATIVE_SURFACE_REPAIR_ONLY:-false}" = true ]; then
    if [ "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" = true ] || [ "${DOOR_NATIVE_SURFACE_ONLY:-false}" = true ] || [ "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" = true ] || [ "${DOOR_UI_EVIDENCE_ONLY:-false}" = true ]; then
        echo "Choose one isolated test phase"; exit 2
    fi
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-surface-repair.sh"
fi
if [ "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" = true ] && [ "${DOOR_NATIVE_SURFACE_ONLY:-false}" = true ]; then
    echo "Choose one isolated test phase"; exit 2
fi
if [ "${DOOR_NATIVE_SURFACE_ONLY:-false}" = true ]; then
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-surface.sh"
fi
if [ "${DOOR_NATIVE_FOUNDATION_ONLY:-false}" = true ]; then
    exec /bin/bash "$TASK_ROOT/scripts/cloud-test-native-foundation.sh"
fi
OUT="$TASK_ROOT/cloud-build"
DERIVED="$OUT/DerivedData"
LOG="$OUT/cloud-build.log"
RESULT="$OUT/cloud-build.result.txt"
PHASE=preflight
PROFILE_OBSERVER_PID=""
mkdir -p "$OUT"
exec > >(tee "$LOG") 2>&1
finish() {
    rc=$?
    if [ -n "$PROFILE_OBSERVER_PID" ]; then
        kill "$PROFILE_OBSERVER_PID" 2>/dev/null || true
        wait "$PROFILE_OBSERVER_PID" || true
    fi
    if [ "$rc" -ne 0 ]; then
        printf "status=FAIL\nphase=%s\nexit=%s\n" "$PHASE" "$rc" > "$RESULT"
        if [ -d "$OUT/native-tests.xcresult" ]; then
            xcrun xcresulttool get test-results summary --path "$OUT/native-tests.xcresult" > "$OUT/native-tests-summary.json" || true
            xcrun xcresulttool export attachments --path "$OUT/native-tests.xcresult" --output-path "$OUT/ui-screenshots/failed-primary" || true
        fi
    fi
}
trap finish EXIT
echo "START $(date -u +%Y-%m-%dT%H:%M:%SZ)"
test "$(uname -s)" = Darwin
test ! -e "$DERIVED"
test ! -e "$OUT/Payload"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
xcodegen --version
cd "$TASK_ROOT"
PHASE=accepted-behavior-regressions
node scripts/test-native-restoration.cjs
node scripts/test-native-cache-lifecycle.cjs
python3 scripts/run-reference-regressions.py --native-only
PHASE=source-parse
xcrun swiftc -frontend -parse DoorMap581/*.swift DoorMap581Tests/*.swift DoorMap581UITests/*.swift
xcodegen generate
test -d DoorMap581.xcodeproj
TEST_FLAGS=(-testLanguage zh-Hant -testRegion TW)
XCODE_HELP="$(xcodebuild -help 2>&1 || true)"
if [[ "$XCODE_HELP" == *"-collect-test-diagnostics"* ]]; then
    TEST_FLAGS+=(-collect-test-diagnostics never)
fi
PHASE=simulator-tests
xcrun simctl list devices available -j > "$OUT/simulator-devices.json"
SIM_UDID="$(python3 -c '
import json,sys
for runtime,items in json.load(open(sys.argv[1])).get("devices",{}).items():
    if ".iOS-" not in runtime: continue
    for item in items:
        if item.get("isAvailable") and item.get("name","").startswith("iPhone"):
            print(item["udid"]); raise SystemExit(0)
raise SystemExit("No available iPhone simulator: tests cannot be claimed PASS")
' "$OUT/simulator-devices.json")"
# macOS bash 3.2 treats expansion of an empty array as unbound under nounset.
ONLY_FLAGS=(-only-testing:DoorMap581Tests -only-testing:DoorMap581UITests -skip-testing:DoorMap581UITests/NativeMemoryUITests)
if [ "${DOOR_UI_EVIDENCE_ONLY:-false}" = true ]; then
    ONLY_FLAGS=(-only-testing:DoorMap581UITests/NativeMapUITests/testSmallScreenLayoutAndLandscape)
fi
if [ "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" = true ]; then
    ONLY_FLAGS=(-only-testing:DoorMap581Tests/NativeResourceTests -only-testing:DoorMap581UITests/NativeMemoryUITests/testRepeatedNavigationDestinationAndBackgroundMemory)
    python3 scripts/observe-simulator-memory.py --device "$SIM_UDID" --out "$OUT/memory" > "$OUT/memory-observer.log" 2>&1 &
    PROFILE_OBSERVER_PID=$!
fi
xcodebuild -project DoorMap581.xcodeproj -scheme DoorMap581 \
    -destination "platform=iOS Simulator,id=$SIM_UDID" -destination-timeout 60 \
    -configuration Debug -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    "${TEST_FLAGS[@]}" "${ONLY_FLAGS[@]}" -resultBundlePath "$OUT/native-tests.xcresult" test
xcrun xcresulttool get test-results summary --path "$OUT/native-tests.xcresult" > "$OUT/native-tests-summary.json"
PHASE=ui-evidence
xcrun xcresulttool export attachments --path "$OUT/native-tests.xcresult" --output-path "$OUT/ui-screenshots/primary"
if [ "${DOOR_MEMORY_EVIDENCE_ONLY:-false}" = true ]; then
    kill "$PROFILE_OBSERVER_PID" 2>/dev/null || true
    wait "$PROFILE_OBSERVER_PID"
    PROFILE_OBSERVER_PID=""
    python3 -c "import json;from pathlib import Path;p=Path('cloud-build/memory/memory-summary.json');d=json.loads(p.read_text());assert d['samples']>20 and d['webkitSamples']>5,'Native and WebKit memory evidence is incomplete';assert not d['deniedOperationsStopped'],'Memory observation access denied: stop and report'"
    printf 'status=PASS\nmode=MEMORY_EVIDENCE_ONLY_NO_NEW_IPA\nfinished=%s\napp_source_tree=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse HEAD:DoorMap581)" > "$RESULT"
    cat "$RESULT"
    exit 0
fi
SECOND_UDID="$(python3 -c '
import json,sys
devices=[d for r,ds in json.load(open(sys.argv[1])).get("devices",{}).items() if ".iOS-" in r for d in ds
         if d.get("isAvailable") and d.get("name", "").startswith("iPhone")]
primary=next(d for d in devices if d["udid"]==sys.argv[2])
others=[d for d in devices if d["name"]!=primary["name"]]
others.sort(key=lambda d: (not any(s in d["name"] for s in ("SE", "mini", "16e", "17e")), "Max" not in d["name"], d["name"]))
if not others: raise SystemExit("A second iPhone size is required for UI evidence")
print(others[0]["udid"])
' "$OUT/simulator-devices.json" "$SIM_UDID")"
PHASE=second-device-ui
xcodebuild -project DoorMap581.xcodeproj -scheme DoorMap581 \
    -destination "platform=iOS Simulator,id=$SECOND_UDID" -destination-timeout 60 \
    -configuration Debug -parallel-testing-enabled NO \
    -maximum-concurrent-test-simulator-destinations 1 \
    -only-testing:DoorMap581UITests/NativeMapUITests/testSmallScreenLayoutAndLandscape \
    "${TEST_FLAGS[@]}" -resultBundlePath "$OUT/second-device-tests.xcresult" test
xcrun xcresulttool get test-results summary --path "$OUT/second-device-tests.xcresult" > "$OUT/second-device-tests-summary.json"
xcrun xcresulttool export attachments --path "$OUT/second-device-tests.xcresult" --output-path "$OUT/ui-screenshots/second"
test "$(find "$OUT/ui-screenshots" -iname '*.png' | wc -l | tr -d ' ')" -gt 0
if [ "${DOOR_UI_EVIDENCE_ONLY:-false}" = true ]; then
    printf 'status=PASS\nmode=SUPPLEMENTAL_UI_ONLY_NO_NEW_IPA\nfinished=%s\napp_source_tree=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse HEAD:DoorMap581)" > "$RESULT"
    cat "$RESULT"
    exit 0
fi
PHASE=device-build
xcodebuild -project DoorMap581.xcodeproj -scheme DoorMap581 \
    -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
PHASE=package
APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/DoorMap581.app"
test -d "$APP_PATH"
mkdir "$OUT/Payload"
cp -R "$APP_PATH" "$OUT/Payload/"
(cd "$OUT" && /usr/bin/zip -9qry DoorMap581-unsigned.ipa Payload)
IPA="$OUT/DoorMap581-unsigned.ipa"
python3 scripts/verify-native-package.py "$IPA" > "$OUT/package-verification.json"
SHA="$(shasum -a 256 "$IPA" | awk '{print $1}')"
{
    echo "status=PASS"
    echo "finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "ipa=$IPA"
    echo "sha256=$SHA"
    echo "xctests=EXECUTED_AND_PASSED"
    echo "package=VERIFIED_UNSIGNED_ARM64_TEST_IDENTITY"
    echo "simulator_udid=$SIM_UDID"
    echo "second_simulator_udid=$SECOND_UDID"
    echo "ui_screenshots=EXPORTED_FOR_REVIEW"
} > "$RESULT"
cat "$RESULT"
