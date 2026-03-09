#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$ROOT/build/TimeWeaver.app}"
DMG="${2:-$ROOT/build/TimeWeaver.dmg}"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/timeweaver-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

if [[ ! -d "$APP" ]]; then
  "$ROOT/build_native_app.sh" "$APP"
fi

rm -f "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "TimeWeaver" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

echo "Created DMG: $DMG"
