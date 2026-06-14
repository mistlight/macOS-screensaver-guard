#!/bin/sh
# test-guard.sh — synthetic decision-logic tests for screensaver-guard.sh.
# Runs the guard in GUARD_DRYRUN mode with injected state (no processes killed)
# and asserts the decision it logs. Exits non-zero if any case fails.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SH="$HERE/../bin/screensaver-guard.sh"
TESTLOG="${TMPDIR:-/tmp}/guard-test.$$.log"
: > "$TESTLOG"
fails=0

run() { # name N IDLE SETTINGS expected
    name="$1"; N="$2"; IDLE="$3"; SET="$4"; EXP="$5"
    GUARD_DRYRUN=1 GUARD_LOG="$TESTLOG" \
        GUARD_TEST_N="$N" GUARD_TEST_IDLE="$IDLE" GUARD_TEST_SETTINGS="$SET" \
        sh "$SH"
    got=$(tail -1 "$TESTLOG" | grep -oE 'healthy|would REAP|skip')
    if [ "$got" = "$EXP" ]; then res="PASS"; else res="FAIL"; fails=$((fails+1)); fi
    printf '%-4s %-26s N=%s idle=%-4s set=%s -> %-10s (want %s)\n' \
        "$res" "$name" "$N" "$IDLE" "$SET" "$got" "$EXP"
}

echo "Testing $SH"
echo "(saver idleTime threshold defaults to 120s when unset)"
echo "--- cases ---"
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

rm -f "$TESTLOG"
echo "--- result ---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
