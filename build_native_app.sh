#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$ROOT/build/TimeWeaver.app}"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

SOURCE_FILES=("$ROOT/PPMSCalendarSync.swift")
if [[ -d "$ROOT/Sources" ]]; then
  while IFS= read -r file; do
    SOURCE_FILES+=("$file")
  done < <(find "$ROOT/Sources" -type f -name '*.swift' | sort)
fi

swiftc -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -framework EventKit \
  -framework Security \
  -o "$BIN_DIR/TimeWeaver" \
  "${SOURCE_FILES[@]}"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/AppIcon.icns" ]]; then
  cp "$ROOT/AppIcon.icns" "$RES_DIR/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built app: $APP"
