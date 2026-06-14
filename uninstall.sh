#!/bin/sh
# uninstall.sh — remove the macOS screensaver guard LaunchAgent.
# Honors the same SUPPORT_DIR / AGENT_DIR / LOG_DIR overrides as install.sh.
set -eu

LABEL="com.mistlight.screensaver-guard"
SUPPORT_DIR="${SUPPORT_DIR:-$HOME/Library/Application Support/ScreensaverGuard}"
AGENT_DIR="${AGENT_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs}"
PLIST_PATH="$AGENT_DIR/$LABEL.plist"
UID_NUM=$(id -u)

echo "==> Uninstalling $LABEL"

launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || echo "    agent not loaded (ok)"
rm -f "$PLIST_PATH" && echo "    removed $PLIST_PATH"
rm -rf "$SUPPORT_DIR" && echo "    removed $SUPPORT_DIR"

echo "==> Done. Logs left in place:"
echo "    $LOG_DIR/screensaver-guard.log"
echo "    $LOG_DIR/screensaver-guard.err.log"
echo "    (delete them manually if you want a clean slate)"
