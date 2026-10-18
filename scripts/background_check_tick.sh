#!/bin/sh
set -eu

# launchd ticks once a minute. Open TimeWeaver only when its configured interval is due.
APP="${1:?TimeWeaver app bundle path is required}"
OPEN_COMMAND="${2:-/usr/bin/open}" # The second argument is for test injection only.
STATE_DIR="$HOME/Library/Application Support/com.jiaze.timeweaver"
SETTINGS="$STATE_DIR/settings.json"
STAMP="$STATE_DIR/background-check-last-run.txt"

[ -x "$APP/Contents/MacOS/TimeWeaver" ] || exit 0
[ -f "$SETTINGS" ] || exit 0

ENABLED=$(/usr/bin/plutil -extract autoSyncEnabled raw -o - "$SETTINGS" 2>/dev/null) || exit 0
[ "$ENABLED" = "true" ] || exit 0
MINUTES=$(/usr/bin/plutil -extract autoSyncMinutes raw -o - "$SETTINGS" 2>/dev/null) || exit 0
case "$MINUTES" in
    ''|*[!0-9]*) exit 0 ;;
esac
# TimeWeaver clamps the UI interval to at least one minute.
[ "$MINUTES" -ge 1 ] || MINUTES=1
# Avoid arithmetic overflow for invalid or extreme settings.
[ "${#MINUTES}" -le 9 ] || exit 0
INTERVAL=$(( MINUTES * 60 ))
NOW=$(date +%s)

if [ -r "$STAMP" ]; then
    LAST=""
    IFS= read -r LAST < "$STAMP" || true
    case "$LAST" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$NOW" -ge "$LAST" ] && [ $(( NOW - LAST )) -lt "$INTERVAL" ]; then
                exit 0
            fi
            ;;
    esac
fi

# Debounce close-together launchd and manual triggers before invoking the GUI app.
TEMP_STAMP="$STAMP.$$"
printf '%s\n' "$NOW" > "$TEMP_STAMP"
mv -f "$TEMP_STAMP" "$STAMP"
exec "$OPEN_COMMAND" -g -a "$APP" --args --background-check-once
