#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$ROOT/build/PPMS Calendar Sync.app}"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

swiftc -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -framework EventKit \
  -o "$BIN_DIR/PPMS Calendar Sync" \
  "$ROOT/PPMSCalendarSync.swift"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/AppIcon.icns" ]]; then
  cp "$ROOT/AppIcon.icns" "$RES_DIR/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built app: $APP"
