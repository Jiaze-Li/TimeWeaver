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
mkdir -p "$HOME/Library/LaunchAgents"

APP_XML="${APP//&/&amp;}"
APP_XML="${APP_XML//</&lt;}"
APP_XML="${APP_XML//>/&gt;}"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AGENT_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-g</string>
        <string>-a</string>
        <string>$APP_XML</string>
        <string>--args</string>
        <string>--background-check-once</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>600</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST"
launchctl bootout "gui/$UID/$AGENT_ID" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Installed 10-minute cold checks for $APP"
