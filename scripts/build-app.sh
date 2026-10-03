#!/bin/bash
set -euo pipefail
FACH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$FACH_ROOT"
swift build -c release --arch arm64
FACH_BIN="$(swift build -c release --arch arm64 --show-bin-path)"
FACH_APP="$FACH_ROOT/build/Fach.app"
mkdir -p "$FACH_APP/Contents/MacOS" "$FACH_APP/Contents/Resources"
cp "$FACH_BIN/Fach" "$FACH_APP/Contents/MacOS/Fach"
cp Packaging/Info.plist "$FACH_APP/Contents/Info.plist"
for FACH_BUNDLE in "$FACH_BIN"/*.bundle; do
  if [ -d "$FACH_BUNDLE" ]; then cp -R "$FACH_BUNDLE" "$FACH_APP/Contents/Resources/"; fi
done
FACH_ICONSET="$FACH_ROOT/build/Fach.iconset"
mkdir -p "$FACH_ICONSET"
for FACH_SIZE in 16 32 128 256 512; do
  sips -z "$FACH_SIZE" "$FACH_SIZE" Sources/FachApp/Resources/FachIcon.png --out "$FACH_ICONSET/icon_${FACH_SIZE}x${FACH_SIZE}.png" >/dev/null
  FACH_DOUBLE=$((FACH_SIZE * 2))
  sips -z "$FACH_DOUBLE" "$FACH_DOUBLE" Sources/FachApp/Resources/FachIcon.png --out "$FACH_ICONSET/icon_${FACH_SIZE}x${FACH_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$FACH_ICONSET" -o "$FACH_APP/Contents/Resources/Fach.icns"
codesign --force --deep --options runtime --entitlements Packaging/Fach.entitlements --sign "${FACH_SIGN_IDENTITY:--}" "$FACH_APP"
codesign --verify --deep --strict "$FACH_APP"
printf 'App: %s\n' "$FACH_APP"
