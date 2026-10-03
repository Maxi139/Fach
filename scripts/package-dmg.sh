#!/bin/bash
set -euo pipefail
FACH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$FACH_ROOT"
bash scripts/build-app.sh
FACH_STAGE="$(mktemp -d "$FACH_ROOT/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$FACH_STAGE"' EXIT
cp -R build/Fach.app "$FACH_STAGE/Fach.app"
ln -s /Applications "$FACH_STAGE/Programme"
hdiutil create -volname Fach -srcfolder "$FACH_STAGE" -ov -format UDZO build/Fach.dmg
if [ -n "${FACH_NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit build/Fach.dmg --keychain-profile "$FACH_NOTARY_PROFILE" --wait
  xcrun stapler staple build/Fach.dmg
fi
printf 'DMG: %s/build/Fach.dmg\n' "$FACH_ROOT"
