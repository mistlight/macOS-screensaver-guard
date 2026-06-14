#!/bin/sh
# screensaver-guard.sh
#
# Auto-recovery for the macOS XScreenSaver "nothing renders / black screen" failure.
#
# Root cause (confirmed on this machine): a stale `legacyScreenSaver` host instance
# survives a sleep/wake or activation cycle and wedges the render path. The host
# keeps running but paints nothing -> black, in BOTH the System Settings preview and
# the full-screen saver, with no crash logs. The proven recovery is to kill the host
# so it is respawned clean on the next activation.
#
# KEY INSIGHT (v2): the wedge happens with even a SINGLE stale host, not only with
# duplicates. While the user is active and not configuring the screensaver in System
# Settings, there should be ZERO legacyScreenSaver hosts -- the host is only meant to
# exist while the saver/preview is on screen. So ANY host lingering while the user is
# active (and Settings is closed) is stale and must be reaped. v1 only reaped when
# n>=2, which is why a single wedged host slipped through and the screen went black
# again.
#
# Safety: we only reap while the user is ACTIVE (idle below the saver threshold), which
# means a real screensaver is NOT on screen, so reaping never interrupts a live saver.
# We also skip while System Settings is open so we don't blink an in-progress preview.
#
# Testability: GUARD_TEST_N / GUARD_TEST_IDLE / GUARD_TEST_SETTINGS inject state, and
# GUARD_DRYRUN=1 logs the decision without killing anything.

LOG="${GUARD_LOG:-$HOME/Library/Logs/screensaver-guard.log}"
PROC="legacyScreenSaver"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# --- gather state (overridable for testing) ---------------------------------
if [ -n "$GUARD_TEST_N" ]; then
    n="$GUARD_TEST_N"
else
    n=$(pgrep -x "$PROC" | wc -l | tr -d ' ')
fi

if [ -n "$GUARD_TEST_IDLE" ]; then
    idle_s="$GUARD_TEST_IDLE"
else
    idle_ns=$(ioreg -c IOHIDSystem 2>/dev/null | awk -F' = ' '/HIDIdleTime/ {print $2; exit}')
    case "$idle_ns" in ''|*[!0-9]*) idle_ns=0 ;; esac
    idle_s=$(( idle_ns / 1000000000 ))
fi

saver_idle=$(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null)
case "$saver_idle" in ''|*[!0-9]*) saver_idle=120 ;; esac

# Is the user actively configuring the screensaver? If so, a host may be running a
# legitimate live preview; don't reap it (would blink the preview every cycle).
if [ -n "$GUARD_TEST_SETTINGS" ]; then
    settings_open="$GUARD_TEST_SETTINGS"
elif pgrep -x "System Settings" >/dev/null 2>&1 || pgrep -x "System Preferences" >/dev/null 2>&1; then
    settings_open=1
else
    settings_open=0
fi

# --- decide -----------------------------------------------------------------
# Healthy: ZERO hosts while active. The host is on-demand; it should not linger.
if [ "$n" -le 0 ]; then
    [ -n "$GUARD_DRYRUN" ] && log "DRYRUN healthy: n=$n (no host), no action"
    exit 0
fi

# A host exists. Decide whether it is stale (reap) or legitimately on screen (skip).
if [ "$idle_s" -ge "$saver_idle" ]; then
    # User idle past the saver threshold -> a real screensaver is (or is about to be)
    # on screen. Never interrupt it.
    [ -n "$GUARD_DRYRUN" ] && log "DRYRUN skip: n=$n idle=${idle_s}s >= saver_idle=${saver_idle}s (saver may be on screen)"
    exit 0
fi

if [ "$settings_open" -ne 0 ]; then
    # User is configuring; the host may be a live preview. Leave it alone.
    [ -n "$GUARD_DRYRUN" ] && log "DRYRUN skip: n=$n but System Settings open (live preview)"
    exit 0
fi

# n>=1, user active, Settings closed -> stale/wedged host. Reap it.
if [ -n "$GUARD_DRYRUN" ]; then
    log "DRYRUN would REAP: n=$n idle=${idle_s}s < saver_idle=${saver_idle}s, Settings closed"
    exit 0
fi
killall legacyScreenSaver 2>/dev/null
killall WallpaperAgent 2>/dev/null
killall WallpaperImageExtension 2>/dev/null
log "REAPED $n stale legacyScreenSaver host(s); idle=${idle_s}s -> clean respawn on next activation"
exit 0
