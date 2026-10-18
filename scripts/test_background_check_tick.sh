#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT HUP INT TERM
export HOME="$FIXTURE"
APP="$FIXTURE/TimeWeaver.app"
STATE_DIR="$HOME/Library/Application Support/com.jiaze.timeweaver"
STAMP="$STATE_DIR/background-check-last-run.txt"
SETTINGS="$STATE_DIR/settings.json"
CALLS="$HOME/mock-open-calls"
MOCK="$FIXTURE/mock-open.sh"
mkdir -p "$APP/Contents/MacOS" "$STATE_DIR"
: > "$APP/Contents/MacOS/TimeWeaver"
chmod +x "$APP/Contents/MacOS/TimeWeaver"

cat > "$MOCK" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/mock-open-calls"
MOCK
chmod +x "$MOCK"

settings() {
    printf '{"autoSyncEnabled":%s,"autoSyncMinutes":%s}\n' "$1" "$2" > "$SETTINGS"
}
count() {
    if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else printf '0\n'; fi
}
expect() {
    ACTUAL=$(count)
    if [ "$ACTUAL" != "$1" ]; then
        echo "Expected $1 launches but got $ACTUAL at: $2" >&2
        exit 1
    fi
}
tick() { /bin/sh "$ROOT/background_check_tick.sh" "$APP" "$MOCK"; }

settings false 10
tick
expect 0 "disabled"
settings true 10
tick
expect 1 "first enabled check"
tick
expect 1 "unchanged interval"

# Switching from 10 to 5 minutes takes effect without reinstalling launchd.
settings true 5
NOW=$(date +%s)
printf '%s\n' "$((NOW - 120))" > "$STAMP"
tick
expect 1 "not yet due at five minutes"
printf '%s\n' "$((NOW - 310))" > "$STAMP"
tick
expect 2 "five-minute check due"

settings true 1
NOW=$(date +%s)
printf '%s\n' "$((NOW - 65))" > "$STAMP"
tick
expect 3 "one-minute check due"

settings false 1
NOW=$(date +%s)
printf '%s\n' "$((NOW - 300))" > "$STAMP"
tick
expect 3 "disabled after previous checks"

printf '{this is invalid JSON' > "$SETTINGS"
tick
expect 3 "invalid settings must fail closed"

# Clock rollback must not permanently suppress cold checks.
settings true 1
NOW=$(date +%s)
printf '%s\n' "$((NOW + 300))" > "$STAMP"
tick
expect 4 "clock rollback"

printf 'Background check interval gating: PASS\n'
