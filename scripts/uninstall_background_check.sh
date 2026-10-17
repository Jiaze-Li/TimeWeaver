#!/bin/zsh
set -euo pipefail

AGENT_ID="com.jiaze.timeweaver.background-check"
PLIST="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
launchctl bootout "gui/$UID/$AGENT_ID" >/dev/null 2>&1 || true
rm -f "$PLIST"
echo "Removed TimeWeaver background check."
