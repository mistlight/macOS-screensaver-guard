#!/bin/sh
# test-guard.sh — synthetic decision-logic tests for screensaver-guard.sh.
# Runs the guard in GUARD_DRYRUN mode with injected state (no processes killed)
# and asserts the decision it logs. Exits non-zero if any case fails.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SH="$HERE/../bin/screensaver-guard.sh"
TESTLOG="${TMPDIR:-/tmp}/guard-test.$$.log"
SCRATCH="${TMPDIR:-/tmp}/guard-test.$$.d"
: > "$TESTLOG"
mkdir -p "$SCRATCH"
fails=0

run() { # name N IDLE SETTINGS expected [SAVER_IDLE]
    name="$1"; N="$2"; IDLE="$3"; SET="$4"; EXP="$5"; SAVER="${6:-120}"
    GUARD_DRYRUN=1 GUARD_LOG="$TESTLOG" GUARD_STAGING="$SCRATCH/healthy-staging" \
        GUARD_TEST_N="$N" GUARD_TEST_IDLE="$IDLE" GUARD_TEST_SETTINGS="$SET" \
        GUARD_TEST_SAVER_IDLE="$SAVER" \
        sh "$SH"
    rc=$?
    got=$(tail -1 "$TESTLOG" | grep -oE 'healthy|would REAP|skip')
    if [ "$got" = "$EXP" ] && [ "$rc" -eq 0 ]; then
        res="PASS"
    else
        res="FAIL"; fails=$((fails+1))
    fi
    printf '%-4s %-28s N=%-4s idle=%-4s set=%-4s saver=%-4s -> %-10s rc=%s (want %s)\n' \
        "$res" "$name" "$N" "$IDLE" "$SET" "${SAVER:-dflt}" "$got" "$rc" "$EXP"
}

# expect_log: run the guard with the given env against a fresh log, then assert
# the log contains a substring (used for health-check and warning cases).
expect_log() { # name expected_substring env assignments...
    name="$1"; want="$2"; shift 2
    : > "$TESTLOG"
    env GUARD_DRYRUN=1 GUARD_LOG="$TESTLOG" \
        GUARD_TEST_N=0 GUARD_TEST_IDLE=5 GUARD_TEST_SETTINGS=0 "$@" sh "$SH"
    rc=$?
    if grep -q "$want" "$TESTLOG" && [ "$rc" -eq 0 ]; then
        res="PASS"
    else
        res="FAIL"; fails=$((fails+1))
    fi
    printf '%-4s %-28s -> rc=%s log: %s\n' "$res" "$name" "$rc" "$(tail -1 "$TESTLOG")"
}

echo "Testing $SH"
echo "(saver idleTime threshold injected as 120s unless a case says otherwise)"
mkdir -p "$SCRATCH/healthy-staging"

echo "--- decision cases ---"
run "no-host-active"        0 5    0 "healthy"
run "no-host-idle"          0 999  0 "healthy"
run "1host-active-noset"    1 5    0 "would REAP"   # the v1 miss: single stale host
run "2host-active-noset"    2 5    0 "would REAP"
run "1host-idle(saver-on)"  1 999  0 "skip"
run "2host-idle(saver-on)"  2 999  0 "skip"
run "1host-active-settings" 1 5    1 "skip"         # live preview, don't blink it
run "1host-boundary-119"    1 119  0 "would REAP"
run "1host-boundary-120"    1 120  0 "skip"
run "5host-active"          5 0    0 "would REAP"

echo "--- hardening: saver set to Never (idleTime=0) ---"
# With the saver disabled, no host is ever legitimate outside Settings:
# reap regardless of idle. (Old logic skipped forever: idle >= 0 always.)
run "never-1host-active"    1 5    0 "would REAP" 0
run "never-1host-idle"      1 999  0 "would REAP" 0
run "never-1host-settings"  1 999  1 "skip"       0
run "never-no-host"         0 5    0 "healthy"    0

echo "--- hardening: unreadable/garbage state fails safe (skip, never reap) ---"
run "idle-unknown-1host"    1 fail 0 "skip"          # idle detection broken -> never kill
run "idle-empty-1host"      1 " "  0 "skip"
run "idle-unknown-never"    1 fail 0 "would REAP" 0  # saver=Never doesn't need idle
run "n-garbage"             x 5    0 "healthy"       # bad count -> treat as none
run "settings-garbage"      1 5    x "skip"          # bad settings state -> assume open
run "saver-garbage-dflt120" 1 119  0 "would REAP" x  # bad threshold -> default 120

echo "--- hardening: container staging health check ---"
mkdir -p "$SCRATCH/containers"
ln -s "$SCRATCH/containers/.Staging" "$SCRATCH/broken-staging"
expect_log "staging-heals-broken-link" "HEALED" GUARD_STAGING="$SCRATCH/broken-staging"
[ -d "$SCRATCH/containers/.Staging" ] || { echo "FAIL staging target not created"; fails=$((fails+1)); }
expect_log "staging-healthy-silent" "healthy" GUARD_STAGING="$SCRATCH/broken-staging"
: > "$SCRATCH/file-staging"
expect_log "staging-file-warns" "WARN" GUARD_STAGING="$SCRATCH/file-staging"

echo "--- hardening: log resilience ---"
# Log dir that doesn't exist yet gets created.
GUARD_DRYRUN=1 GUARD_LOG="$SCRATCH/newdir/sub/guard.log" GUARD_STAGING="$SCRATCH/healthy-staging" \
    GUARD_TEST_N=0 GUARD_TEST_IDLE=5 GUARD_TEST_SETTINGS=0 sh "$SH"
if [ -f "$SCRATCH/newdir/sub/guard.log" ]; then echo "PASS log-dir-created"; else echo "FAIL log-dir-created"; fails=$((fails+1)); fi
# Unwritable log never breaks the exit code.
GUARD_DRYRUN=1 GUARD_LOG=/dev/null/impossible.log GUARD_STAGING="$SCRATCH/healthy-staging" \
    GUARD_TEST_N=0 GUARD_TEST_IDLE=5 GUARD_TEST_SETTINGS=0 sh "$SH"
if [ $? -eq 0 ]; then echo "PASS log-unwritable-exit0"; else echo "FAIL log-unwritable-exit0"; fails=$((fails+1)); fi
# Oversized log gets rotated down.
awk 'BEGIN { for (i = 0; i < 20000; i++) print "2026-01-01 00:00:00 filler line to grow the log file" }' > "$SCRATCH/big.log"
GUARD_DRYRUN=1 GUARD_LOG="$SCRATCH/big.log" GUARD_STAGING="$SCRATCH/healthy-staging" \
    GUARD_TEST_N=0 GUARD_TEST_IDLE=5 GUARD_TEST_SETTINGS=0 sh "$SH"
size=$(wc -c < "$SCRATCH/big.log" | tr -d ' ')
if [ "$size" -lt 262144 ]; then echo "PASS log-rotated (now ${size}B)"; else echo "FAIL log-rotated (still ${size}B)"; fails=$((fails+1)); fi
# Repeated identical warnings are logged once, not every tick.
: > "$TESTLOG"
for i in 1 2 3; do
    GUARD_DRYRUN= GUARD_LOG="$TESTLOG" GUARD_STAGING="$SCRATCH/file-staging" \
        GUARD_TEST_N=0 GUARD_TEST_IDLE=5 GUARD_TEST_SETTINGS=0 sh "$SH"
done
warns=$(grep -c WARN "$TESTLOG")
if [ "$warns" -eq 1 ]; then echo "PASS warn-throttled"; else echo "FAIL warn-throttled (got $warns lines)"; fails=$((fails+1)); fi

rm -rf "$TESTLOG" "$SCRATCH"
echo "--- result ---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
