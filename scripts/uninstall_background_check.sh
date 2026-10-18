#!/bin/zsh
set -euo pipefail

AGENT_ID="com.jiaze.timeweaver.background-check"
PLIST="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
CHECKER="$HOME/Library/Application Support/com.jiaze.timeweaver/background_check_tick.sh"
STAMP="$HOME/Library/Application Support/com.jiaze.timeweaver/background-check-last-run.txt"
launchctl bootout "gui/$UID/$AGENT_ID" >/dev/null 2>&1 || true
rm -f "$PLIST" "$CHECKER" "$STAMP"
echo "Removed TimeWeaver background check."
