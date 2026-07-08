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
# HARDENING (v4):
#   - HOST-AGE GATE (self-inflicted-black-screen fix): legacyScreenSaver is a managed
#     appex owned by WallpaperAgent. Killing a host WHILE WallpaperAgent is starting it
#     throws WallpaperAgent into an unrecoverable loop -- "could not acquire startup
#     assertion" / "plugin is already activating" / "killing plugin" -- which paints a
#     black screen the guard itself caused. Confirmed on this machine 2026-07-07: the
#     only assertion storm in 30h was the exact second a reap raced a just-spawned host;
#     none of the day's 39 reaps of already-idle hosts stormed. So we now NEVER reap a
#     host younger than MIN_HOST_AGE seconds (default 10) -- a fresh host is presumed to
#     be a legitimate in-progress activation; if it is truly wedged it will still be
#     there, and older than the gate, on the next tick. Age is read from `ps -o etime=`
#     (macOS `ps` has no `etimes` keyword) and fails safe: unreadable age -> skip.
#   - OBSERVABILITY: the guard used to log only when it reaped, so a healthy-but-idle
#     guard looked identical to a dead one -- the recurring "is this thing even running?"
#     confusion. It now touches a liveness file every run (mtime = last successful run,
#     check with `stat -f %m`) and emits a throttled "OK alive" heartbeat line at most
#     once per HEARTBEAT_SECS (default 1800s). Both writes are best-effort and can never
#     break the guard.
#   - WallpaperAgent bounce is now opt-out (GUARD_NO_WALLPAPER_KILL=1). It is kept on by
#     default because bouncing WallpaperAgent is what RECOVERS a wedged host, but the
#     age gate above means it now fires only on genuine stale-host reaps, not every tick.
#
# Safety: we only reap while the user is ACTIVE (idle below the saver threshold), which
# means a real screensaver is NOT on screen, so reaping never interrupts a live saver.
# We also skip while System Settings is open so we don't blink an in-progress preview,
# and skip any host still inside its startup window (age gate) so we never race it.
#
# Testability: GUARD_TEST_N / GUARD_TEST_IDLE / GUARD_TEST_SETTINGS /
# GUARD_TEST_SAVER_IDLE / GUARD_TEST_HOST_AGE inject state, GUARD_STAGING overrides the
# health-check path, GUARD_STATE_DIR overrides the liveness/heartbeat dir,
# GUARD_HEARTBEAT_SECS tunes the heartbeat cadence (0 = every run), and GUARD_DRYRUN=1
# logs the decision without killing anything.
set -u

LOG="${GUARD_LOG:-$HOME/Library/Logs/screensaver-guard.log}"
PROC="legacyScreenSaver"
STAGING="${GUARD_STAGING:-$HOME/Library/ContainerManager/Staging}"
STATE_DIR="${GUARD_STATE_DIR:-$HOME/Library/Application Support/ScreensaverGuard}"
LIVENESS="$STATE_DIR/last-run"
HEARTBEAT="$STATE_DIR/heartbeat"
HEARTBEAT_SECS=$(printf '%s' "${GUARD_HEARTBEAT_SECS:-1800}" | tr -cd '0-9'); HEARTBEAT_SECS=${HEARTBEAT_SECS:-1800}
MIN_HOST_AGE=$(printf '%s' "${GUARD_MIN_HOST_AGE:-10}" | tr -cd '0-9'); MIN_HOST_AGE=${MIN_HOST_AGE:-10}
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

# youngest_host_age PIDLIST — print the age in seconds of the *youngest* pid in the
# space/comma list, or nothing if it cannot be read. macOS `ps` has no `etimes`
# keyword, so we parse `etime` ([[dd-]hh:]mm:ss). We use the youngest host because
# that is the one most likely to be mid-startup; if it is old enough to reap, every
# host is.
youngest_host_age() {
    ps -o etime= -p "$1" 2>/dev/null | awk '
        {
            s=$1; d=0
            n=split(s, a, "-"); if (n==2) { d=a[1]; s=a[2] }
            m=split(s, b, ":")
            if      (m==3) secs=b[1]*3600 + b[2]*60 + b[3]
            else if (m==2) secs=b[1]*60 + b[2]
            else           secs=b[1]
            secs += d*86400
            if (found==0 || secs<min) { min=secs; found=1 }
        }
        END { if (found) print min }'
}

# heartbeat: prove liveness even on quiet ticks. Touch a file every run (its mtime is
# the last-run time) and emit one throttled "OK alive" line per HEARTBEAT_SECS. All
# best-effort; never aborts the guard or changes its exit code.
heartbeat() {
    { mkdir -p "$STATE_DIR" && : > "$LIVENESS"; } 2>/dev/null || :
    due=1
    if [ -f "$HEARTBEAT" ]; then
        hb_mtime=$(stat -f %m "$HEARTBEAT" 2>/dev/null) || hb_mtime=""
        now=$(date +%s 2>/dev/null) || now=""
        hb_mtime=$(as_int "$hb_mtime" ""); now=$(as_int "$now" "")
        if [ -n "$hb_mtime" ] && [ -n "$now" ] && [ "$((now - hb_mtime))" -lt "$HEARTBEAT_SECS" ]; then
            due=0
        fi
    fi
    if [ "$due" -eq 1 ]; then
        { mkdir -p "$STATE_DIR" && : > "$HEARTBEAT"; } 2>/dev/null || :
        log "OK alive: $1"
    fi
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

# --- liveness / heartbeat (runs on every tick, healthy or not) -------------------
heartbeat "n=$n idle=${idle_s:-unknown}s saver_idle=${saver_idle}s settings=$settings_open"

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

# --- host-age gate (do not race WallpaperAgent's startup) ------------------------
# A host still inside its startup window is almost certainly a legitimate activation
# in progress. Killing it there wedges WallpaperAgent ("could not acquire startup
# assertion" / "already activating") and paints the very black screen we exist to
# prevent. Never reap a host younger than MIN_HOST_AGE. Fail safe: if the age cannot
# be read, skip (treat as "might be starting"), never kill blindly.
if [ -n "${GUARD_TEST_HOST_AGE:-}" ]; then
    host_age=$(as_int "$GUARD_TEST_HOST_AGE" "")
else
    pids=$(pgrep -U "$UID_NUM" -x "$PROC" 2>/dev/null | tr '\n' ' ')
    pids=$(printf '%s' "$pids" | sed 's/[[:space:]]*$//')
    if [ -n "$pids" ]; then
        host_age=$(youngest_host_age "$(printf '%s' "$pids" | tr ' ' ',')")
        host_age=$(as_int "$host_age" "")
    else
        host_age=""
    fi
fi
if [ -z "$host_age" ]; then
    log_once "WARN host age unreadable (ps etime); failing safe: not reaping (a host may be mid-startup)"
    [ -n "${GUARD_DRYRUN:-}" ] && log "DRYRUN skip: n=$n host_age=unknown (fail-safe)"
    exit 0
fi
if [ "$host_age" -lt "$MIN_HOST_AGE" ]; then
    # Fresh host -> presumed legitimate in-progress activation. Leave it; if it is
    # actually wedged it will still be here, and older, next tick.
    [ -n "${GUARD_DRYRUN:-}" ] && log "DRYRUN skip: n=$n host_age=${host_age}s < min=${MIN_HOST_AGE}s (mid-startup, don't race)"
    exit 0
fi

# Stale/wedged host. Reap it (own user's processes only).
if [ -n "${GUARD_DRYRUN:-}" ]; then
    log "DRYRUN would REAP: n=$n idle=${idle_s:-unknown}s host_age=${host_age}s saver_idle=${saver_idle}s, Settings closed"
    exit 0
fi
killall -u "$USER_NAME" legacyScreenSaver 2>/dev/null
if [ -z "${GUARD_NO_WALLPAPER_KILL:-}" ]; then
    # Bouncing WallpaperAgent is what RECOVERS a wedged host; the age gate above keeps
    # this from firing on every tick. Opt out with GUARD_NO_WALLPAPER_KILL=1.
    killall -u "$USER_NAME" WallpaperAgent 2>/dev/null
    killall -u "$USER_NAME" WallpaperImageExtension 2>/dev/null
fi
log "REAPED $n stale legacyScreenSaver host(s); idle=${idle_s:-unknown}s host_age=${host_age}s -> clean respawn on next activation"
exit 0
