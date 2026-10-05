#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/native-only-build"
DERIVED="$OUT/DerivedData"
mkdir -p "$OUT"
exec > >(tee "$OUT/package.log") 2>&1
cd "$ROOT"
chmod +x scripts/prepare-native-only-resources.sh
scripts/prepare-native-only-resources.sh
xcodegen generate --spec project-native.yml
test -d DoorMap581Native.xcodeproj

for f in AppleSearchBridge.swift DoorMapViewController.swift LocationBridge.swift NativeBridge.swift NativeMemoryProfile.swift NLSCMiniMapView.swift RestoredAppleMapViewController.swift NativeControlsWebView.swift NativeBundleServer.swift NativeAppleMapViewController.swift; do
  if grep -q "$f" DoorMap581Native.xcodeproj/project.pbxproj; then
    echo "legacy source present: $f"; exit 20
  fi
done

xcodebuild -project DoorMap581Native.xcodeproj -scheme DoorMap581   -configuration Release -sdk iphoneos -destination 'generic/platform=iOS'   -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

APP="$DERIVED/Build/Products/Release-iphoneos/DoorMap581.app"
BIN="$APP/DoorMap581"
test -d "$APP"
file "$BIN" | grep -q arm64
if otool -L "$BIN" | grep -qi WebKit; then echo "WebKit linked"; exit 31; fi
if find "$APP" -type f \( -iname '*.js' -o -iname '*.html' -o -iname '*.css' -o -iname '*.webmanifest' \) | grep -q .; then
  echo "web runtime asset present"; exit 32
fi
if find "$APP" -type f | grep -Ei 'maplibre|planner-ui|door-map\.js|native-map-engine\.js' | grep -q .; then
  echo "legacy web/map runtime present"; exit 33
fi

BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
test "$BID" = "com.door581.appletest"
test "$VER" = "0.4.0"
test "$BUILD" = "9"
test -d "$APP/Behavior"
test -f "$APP/NativeData/seed-catalog.json"
test -f "$APP/battery-stations-fallback.json"

mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && /usr/bin/zip -9qry DoorMap581Native-v0.4.0-build9-unsigned.ipa Payload)
IPA="$OUT/DoorMap581Native-v0.4.0-build9-unsigned.ipa"
SHA=$(shasum -a 256 "$IPA" | awk '{print $1}')
BYTES=$(stat -f%z "$IPA")
cat > "$OUT/package.result.txt" <<EOF
status=PASS
bundle_id=$BID
version=$VER
build=$BUILD
sha256=$SHA
bytes=$BYTES
webkit_linked=NO
web_runtime_assets=NO
unsigned_arm64=YES
EOF
cat "$OUT/package.result.txt"
