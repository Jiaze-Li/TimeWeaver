#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="${1:-$ROOT/build/TimeWeaver.app}"
if [[ ! -x "$APP/Contents/MacOS/TimeWeaver" ]]; then
  echo "App not found at $APP; run ./build_native_app.sh first." >&2
  exit 1
fi
APP="$(cd "$APP" && pwd -P)"
AGENT_ID="com.jiaze.timeweaver.background-check"
PLIST="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
CHECKER="$HOME/Library/Application Support/com.jiaze.timeweaver/background_check_tick.sh"
mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$CHECKER")"

# Use a stable installed copy so the repository may be moved after setup.
cp "$ROOT/scripts/background_check_tick.sh" "$CHECKER"
chmod 700 "$CHECKER"

APP_XML="${APP//&/&amp;}"
APP_XML="${APP_XML//</&lt;}"
APP_XML="${APP_XML//>/&gt;}"
CHECKER_XML="${CHECKER//&/&amp;}"
CHECKER_XML="${CHECKER_XML//</&lt;}"
CHECKER_XML="${CHECKER_XML//>/&gt;}"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$CHECKER_XML</string>
        <string>$APP_XML</string>
    </array>
    <key>RunAtLoad</key><true/>
    <!-- The cheap gate runs every minute; the app opens only at the configured interval. -->
    <key>StartInterval</key><integer>60</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST"
launchctl bootout "gui/$UID/$AGENT_ID" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Installed adaptive background checks for $APP"
echo "TimeWeaver's saved Interval (minutes) now controls cold checks without reinstalling."
