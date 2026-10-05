#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DST="$ROOT/NativeOnlyBuild/Resources"
if [ -d "$DST" ]; then find "$DST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; fi
mkdir -p "$DST/Behavior" "$DST/NativeData"
for dir in assets native-data official-lookup offline; do
  cp -R "$ROOT/DoorMap581/Behavior/$dir" "$DST/Behavior/$dir"
done
cp "$ROOT/DoorMap581/NativeData/seed-catalog.json" "$DST/NativeData/seed-catalog.json"
cp "$ROOT/DoorMap581/battery-stations-fallback.json" "$DST/battery-stations-fallback.json"
