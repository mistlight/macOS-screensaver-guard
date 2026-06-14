#!/bin/sh
# install.sh — install the macOS screensaver guard LaunchAgent.
#
# Idempotent: re-running cleanly reinstalls over an existing install.
# Override install locations with env vars (used by tests):
#   SUPPORT_DIR  default: ~/Library/Application Support/ScreensaverGuard
#   AGENT_DIR    default: ~/Library/LaunchAgents
#   LOG_DIR      default: ~/Library/Logs
set -eu

LABEL="com.mistlight.screensaver-guard"
HERE=$(cd "$(dirname "$0")" && pwd)

SUPPORT_DIR="${SUPPORT_DIR:-$HOME/Library/Application Support/ScreensaverGuard}"
AGENT_DIR="${AGENT_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs}"

SCRIPT_PATH="$SUPPORT_DIR/screensaver-guard.sh"
PLIST_PATH="$AGENT_DIR/$LABEL.plist"
LOG="$LOG_DIR/screensaver-guard.log"
ERRLOG="$LOG_DIR/screensaver-guard.err.log"
UID_NUM=$(id -u)

echo "==> Installing $LABEL"

# 1. Install the script.
mkdir -p "$SUPPORT_DIR" "$LOG_DIR"
cp "$HERE/bin/screensaver-guard.sh" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"
sh -n "$SCRIPT_PATH"
echo "    script  -> $SCRIPT_PATH"

# 2. Render the plist from the template.
mkdir -p "$AGENT_DIR"
sed -e "s|__SCRIPT_PATH__|$SCRIPT_PATH|g" \
    -e "s|__ERRLOG__|$ERRLOG|g" \
    "$HERE/launchd/$LABEL.plist.template" > "$PLIST_PATH"
plutil -lint "$PLIST_PATH" >/dev/null
echo "    plist   -> $PLIST_PATH (plutil OK)"

# 3. (Re)load the agent.
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    echo "    existing agent found -> bootout first"
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
fi
launchctl bootstrap "gui/$UID_NUM" "$PLIST_PATH"
launchctl kickstart "gui/$UID_NUM/$LABEL"

# 4. Verify.
sleep 1
EXIT=$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | awk -F'= ' '/last exit code/ {print $2; exit}')
echo "==> Installed. last exit code = ${EXIT:-unknown}"
echo "    logs: $LOG"
echo "    status: launchctl print gui/$UID_NUM/$LABEL"
