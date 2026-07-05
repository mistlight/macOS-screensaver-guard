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
# HARDENING (v3):
#   - Fail safe: if any state read is missing or garbled (ioreg format change,
#     unreadable defaults), the guard SKIPS rather than risking a kill of a saver
#     that is legitimately on screen. The only exception is idleTime=0 ("Never"),
#     where no host is ever legitimate outside Settings, so idle time is irrelevant.
#   - idleTime=0 ("start Never"): the old check `idle >= threshold` was always true,
#     so wedged hosts were never reaped. Now handled explicitly.
#   - Per-user scoping: process counting and kills are restricted to the current
#     user so the guard never miscounts or signals another login session's saver.
#   - Container staging health check: a broken ~/Library/ContainerManager/Staging
#     symlink (target deleted) makes sandboxed ScreenSaverEngine quit ~20ms after
#     every launch -> black screen with NO host to reap, invisible to the watchdog.
#     Confirmed on this machine 2026-07-04. The guard restores the missing symlink
#     target (the Containers side is writable without Full Disk Access) and logs it.
#   - Logging can never break the guard: log dir is created on demand, write
#     failures are swallowed, the log is rotated at 256 KB, repeated identical
#     warnings are throttled, and the script always exits 0 so launchd stays happy.
#
# Safety: we only reap while the user is ACTIVE (idle below the saver threshold), which
# means a real screensaver is NOT on screen, so reaping never interrupts a live saver.
# We also skip while System Settings is open so we don't blink an in-progress preview.
#
# Testability: GUARD_TEST_N / GUARD_TEST_IDLE / GUARD_TEST_SETTINGS /
# GUARD_TEST_SAVER_IDLE inject state, GUARD_STAGING overrides the health-check path,
# and GUARD_DRYRUN=1 logs the decision without killing anything.
set -u

LOG="${GUARD_LOG:-$HOME/Library/Logs/screensaver-guard.log}"
PROC="legacyScreenSaver"
STAGING="${GUARD_STAGING:-$HOME/Library/ContainerManager/Staging}"
UID_NUM=$(id -u)
USER_NAME=$(id -un)
MAX_LOG_BYTES=262144

# --- logging: must never abort the guard or change its exit code ---------------
log() {
    { mkdir -p "$(dirname "$LOG")" &&
      printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; } 2>/dev/null || :
}

# Skip the write if the identical message is already the last line, so a
# persistent condition warns once instead of spamming every 60s tick.
log_once() {
    last=$(tail -1 "$LOG" 2>/dev/null | cut -d' ' -f3-) || last=""
    [ "$last" = "$1" ] || log "$1"
}

rotate_log() {
    size=$({ wc -c < "$LOG"; } 2>/dev/null | tr -d ' ')
    case "${size:-}" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
        { tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; } 2>/dev/null || :
    fi
}

# as_int VALUE FALLBACK — print VALUE if it is a plain non-negative integer,
# else FALLBACK. Every external read goes through this before arithmetic/tests.
as_int() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$1" ;;
    esac
}

rotate_log

# --- health check: engine container staging ------------------------------------
# ScreenSaverEngine is sandboxed; every launch stages a container dir through
# $STAGING. If that path is a symlink whose target was deleted, the engine dies
# before drawing anything (MCMErrorDomain CREATE_STAGING_DIRECTORY, errno 20) and
# the screen goes black with zero hosts running. Restore the target if we can.
if [ ! -d "$STAGING" ]; then
    healed=0
    if [ -L "$STAGING" ]; then
        target=$(readlink "$STAGING" 2>/dev/null) || target=""
        case "$target" in
            "") : ;;
            /*) : ;;
            *)  target="$(dirname "$STAGING")/$target" ;;
        esac
        if [ -n "$target" ] && mkdir -p "$target" 2>/dev/null; then
            log "HEALED container staging: restored missing symlink target $target (ScreenSaverEngine cannot launch without it)"
            healed=1
        fi
    fi
    [ "$healed" -eq 1 ] || log_once "WARN container staging unusable: $STAGING is not a directory -> sandboxed ScreenSaverEngine may fail to launch (black screensaver). Fixing it may need Full Disk Access."
fi

# --- gather state (overridable for testing) -------------------------------------
if [ -n "${GUARD_TEST_N:-}" ]; then
    n=$(as_int "$GUARD_TEST_N" 0)
else
    n=$(pgrep -U "$UID_NUM" -x "$PROC" 2>/dev/null | wc -l | tr -d ' ')
    n=$(as_int "$n" 0)
fi

# idle_s is "" when idle time cannot be determined (fail-safe: treated as
# "a saver might be on screen", never as "user is active").
if [ -n "${GUARD_TEST_IDLE:-}" ]; then
    idle_s=$(as_int "$GUARD_TEST_IDLE" "")
else
    idle_ns=$(ioreg -c IOHIDSystem 2>/dev/null | awk -F' = ' '/HIDIdleTime/ {print $2; exit}')
    idle_ns=$(as_int "$idle_ns" "")
    if [ -n "$idle_ns" ]; then idle_s=$(( idle_ns / 1000000000 )); else idle_s=""; fi
fi

if [ -n "${GUARD_TEST_SAVER_IDLE:-}" ]; then
    saver_idle=$(as_int "$GUARD_TEST_SAVER_IDLE" 120)
else
    saver_idle=$(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null)
    saver_idle=$(as_int "$saver_idle" 120)
fi

# Is the user actively configuring the screensaver? If so, a host may be running a
# legitimate live preview; don't reap it (would blink the preview every cycle).
# Unreadable state fails safe as "open".
if [ -n "${GUARD_TEST_SETTINGS:-}" ]; then
    settings_open=$(as_int "$GUARD_TEST_SETTINGS" 1)
elif pgrep -U "$UID_NUM" -x "System Settings" >/dev/null 2>&1 ||
     pgrep -U "$UID_NUM" -x "System Preferences" >/dev/null 2>&1; then
    settings_open=1
else
    settings_open=0
fi

# --- decide ----------------------------------------------------------------------
# Healthy: ZERO hosts while active. The host is on-demand; it should not linger.
if [ "$n" -le 0 ]; then
    [ -n "${GUARD_DRYRUN:-}" ] && log "DRYRUN healthy: n=$n (no host), no action"
    exit 0
fi

# A host exists. Decide whether it is stale (reap) or legitimately on screen (skip).
if [ "$settings_open" -ne 0 ]; then
    # User is configuring; the host may be a live preview. Leave it alone.
    [ -n "${GUARD_DRYRUN:-}" ] && log "DRYRUN skip: n=$n but System Settings open (live preview)"
    exit 0
fi

if [ "$saver_idle" -ne 0 ]; then
    # Normal case: the saver activates after $saver_idle seconds of idle.
    if [ -z "$idle_s" ]; then
        # Idle time unreadable: we cannot prove a saver is NOT on screen, so
        # never kill. This is the fail-safe direction; the old behavior of
        # assuming idle=0 would kill a saver mid-display.
        log_once "WARN idle time unreadable (ioreg HIDIdleTime); failing safe: not reaping while a saver might be on screen"
        [ -n "${GUARD_DRYRUN:-}" ] && log "DRYRUN skip: n=$n idle=unknown (fail-safe)"
        exit 0
    fi
    if [ "$idle_s" -ge "$saver_idle" ]; then
        # User idle past the saver threshold -> a real screensaver is (or is about
        # to be) on screen. Never interrupt it.
        [ -n "${GUARD_DRYRUN:-}" ] && log "DRYRUN skip: n=$n idle=${idle_s}s >= saver_idle=${saver_idle}s (saver may be on screen)"
        exit 0
    fi
fi
# saver_idle=0 means "start Never": no host is ever legitimately on screen outside
# Settings, so any host is stale regardless of idle time -- fall through to reap.

# Stale/wedged host. Reap it (own user's processes only).
if [ -n "${GUARD_DRYRUN:-}" ]; then
    log "DRYRUN would REAP: n=$n idle=${idle_s:-unknown}s saver_idle=${saver_idle}s, Settings closed"
    exit 0
fi
killall -u "$USER_NAME" legacyScreenSaver 2>/dev/null
killall -u "$USER_NAME" WallpaperAgent 2>/dev/null
killall -u "$USER_NAME" WallpaperImageExtension 2>/dev/null
log "REAPED $n stale legacyScreenSaver host(s); idle=${idle_s:-unknown}s -> clean respawn on next activation"
exit 0
