#!/bin/bash
# S8 native normal-navigation camera + HUD only. No IPA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/cloud-build"
mkdir -p "$OUT/native-port"
exec > >(tee "$OUT/cloud-build.log") 2>&1
PHASE=preflight
finish() {
 rc=$?
 if [ "$rc" -ne 0 ]; then
  printf 'status=FAIL\nmode=NATIVE_NAVIGATION_ONLY_NO_IPA\nphase=%s\nexit=%s\n' "$PHASE" "$rc" > "$OUT/cloud-build.result.txt"
  if [ -d "$OUT/native-tests.xcresult" ]; then
   xcrun xcresulttool get test-results summary --path "$OUT/native-tests.xcresult" > "$OUT/native-tests-summary.json" || true
   xcrun xcresulttool export attachments --path "$OUT/native-tests.xcresult" --output-path "$OUT/native-port/failed-ui-evidence" || true
  fi
 fi
}
trap finish EXIT
cd "$ROOT"
test "$(uname -s)" = Darwin
test ! -e "$OUT/Payload"
PHASE=source-parsing
find DoorMap581 DoorMap581Tests DoorMap581UITests NativeCoreTests -name '*.swift' -print0 | xargs -0 xcrun swiftc -frontend -parse
python3 - <<'PY'
from pathlib import Path
for n in ['NativeRidingCamera.swift','NativePortViewController.swift','NativeRoutePlanner.swift']:
 s=Path('DoorMap581',n).read_text()
 assert 'import WebKit' not in s and 'evaluateJavaScript(' not in s and 'NativeBundleServer(' not in s,n
assert 'case free, north, heading, navigation, fit' in Path('DoorMap581/NativeRidingCamera.swift').read_text()
assert '58.0' in Path('DoorMap581/NativeRidingCamera.swift').read_text()
assert '個人路線' in Path('DoorMap581/NativePortViewController.swift').read_text()
scene=Path('DoorMap581/SceneDelegate.swift').read_text()
assert 'Bundle.main.bundleIdentifier == "com.door581.appletest"' in scene
assert '--hybrid-rollback' in scene
PY
TEST_FLAGS=(-testLanguage zh-Hant -testRegion TW)
HELP="$(xcodebuild -help 2>&1 || true)"
if [[ "$HELP" == *"-collect-test-diagnostics"* ]]; then TEST_FLAGS+=(-collect-test-diagnostics never); fi
xcodegen generate
xcrun simctl list devices available -j > "$OUT/simulator-devices.json"
SIM="$(python3 -c 'import json; ds=json.load(open("cloud-build/simulator-devices.json"))["devices"]; print(next(d["udid"] for r,rows in ds.items() if ".iOS-" in r for d in rows if d.get("isAvailable") and d["name"].startswith("iPhone")))')"
PHASE=native-navigation-tests
xcodebuild -project DoorMap581.xcodeproj -scheme DoorMap581 \
 -destination "platform=iOS Simulator,id=$SIM" -destination-timeout 60 \
 -configuration Debug -derivedDataPath "$OUT/DerivedData" -parallel-testing-enabled NO \
 -maximum-concurrent-test-simulator-destinations 1 "${TEST_FLAGS[@]}" \
 -only-testing:DoorMap581Tests/NativeRidingTests/testNormalNavigationUsesPinnedStable3DAndArrivalLock \
 -only-testing:DoorMap581Tests/MapPreferencesTests/testPreferencesSurviveStoreReloadAndInvalidValuesAreClamped \
 -only-testing:DoorMap581Tests/NativeGoogleHandoffTests \
 -only-testing:DoorMap581Tests/NativeDestinationSyncTests \
 -only-testing:DoorMap581Tests/NativeReroutePolicyTests \
 -only-testing:DoorMap581Tests/NativePublicLayerTests \
 -only-testing:DoorMap581Tests/NativePowerDiagnosticTests \
 -only-testing:DoorMap581Tests/NativeGzipTests \
 -only-testing:DoorMap581Tests/NativeSeedTests/testInstalledCopyCanBeDeletedAndBundledSearchStillWorks \
 -only-testing:DoorMap581Tests/NativeSeedTests/testNetworkPayloadMustReproduceAcceptedDecodedAndGzipHashes \
 -only-testing:DoorMap581UITests/NativeRidingUITests/testNormal3DNavigationHUDUsesRouteFirstCamera \
 -only-testing:DoorMap581UITests/NativeSettingsUITests/testMapSettingsApplyOfflineStationsAndRouteVisibilityThenRestore \
 -only-testing:DoorMap581UITests/NativeSettingsUITests/testPowerDiagnosticStartsAndStopsWithoutWebRuntime \
 -only-testing:DoorMap581UITests/NativeSettingsUITests/testMapCenterPickerTracksPanAndNavigatesExplicitCenter \
 -resultBundlePath "$OUT/native-tests.xcresult" test
xcrun xcresulttool get test-results summary --path "$OUT/native-tests.xcresult" > "$OUT/native-tests-summary.json"
xcrun xcresulttool export attachments --path "$OUT/native-tests.xcresult" --output-path "$OUT/native-port/ui-evidence"
PHASE=apple-sdk-build
xcodebuild -project DoorMap581.xcodeproj -scheme DoorMap581 -sdk iphoneos -destination 'generic/platform=iOS' \
 -configuration Debug -derivedDataPath "$OUT/DeviceDerived" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build-for-testing >/dev/null
PHASE=verify-result
python3 - <<'PY'
import datetime,hashlib,json,subprocess
from pathlib import Path
r=Path.cwd(); out=r/'cloud-build/native-port'; s=json.loads((r/'cloud-build/native-tests-summary.json').read_text())
assert s.get('passedTests')==26 and s.get('totalTestCount')==26 and s.get('failedTests')==0 and s.get('skippedTests')==0,s
assert not list((r/'cloud-build').glob('*.ipa'))
shots=list((out/'ui-evidence').rglob('*.png')); assert len(shots)>=1,shots
paths=['DoorMap581/SceneDelegate.swift','DoorMap581/NativeRidingCamera.swift','DoorMap581/NativePortViewController.swift','DoorMap581/MapPreferences.swift','DoorMap581/MapSettingsViewController.swift','DoorMap581/BatteryStations.swift','DoorMap581/NativeGoogleHandoff.swift','DoorMap581/NativeDestinationSync.swift','DoorMap581/NativeCore/NativeReroutePolicy.swift','DoorMap581/NativePublicLayers.swift','DoorMap581/NativePowerDiagnostic.swift','DoorMap581/NativeGzip.swift','DoorMap581/NativePublicResources.swift','DoorMap581/NativeOfflineViewController.swift','DoorMap581/NativeCore/NativeOfflineStore.swift','DoorMap581/NativeScene.swift','DoorMap581Tests/NativeGoogleHandoffTests.swift','DoorMap581Tests/NativeDestinationSyncTests.swift','NativeCoreTests/NativeReroutePolicyTests.swift','DoorMap581Tests/NativePublicLayerTests.swift','DoorMap581Tests/NativePowerDiagnosticTests.swift','DoorMap581Tests/NativeGzipTests.swift','DoorMap581Tests/NativeSeedTests.swift','DoorMap581UITests/NativeSettingsUITests.swift']
result={'status':'PASS','mode':'S10_NATIVE_FULL_ENTRY_AND_HANDOFF_REAL_UI','at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'passed':26,'failed':0,'skipped':0,'sourceHashes':{p:hashlib.sha256((r/p).read_bytes()).hexdigest() for p in paths},'uiScreenshots':len(shots),'newIPA':False,'physicalDeviceAccepted':False,'all26Complete':False}
(out/'S10_NATIVE_FULL_RESULT.json').write_text(json.dumps(result,indent=2)+'\n')
PY
printf 'status=PASS\nmode=NATIVE_NAVIGATION_ONLY_NO_IPA\ntests=26\nphysical_device=NOT_TESTED\nall26=NOT_COMPLETE\nfinished=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/cloud-build.result.txt"
