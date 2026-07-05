# macOS Screensaver Guard — fix XScreenSaver / legacyScreenSaver black screen

**A tiny launchd watchdog that auto-restarts the macOS screensaver host when it
wedges and shows a black screen.** If your screensaver — especially
[XScreenSaver](https://www.jwz.org/xscreensaver/) — suddenly stopped working and
just renders **black / nothing**, with no crash dialog, this fixes it and keeps
it fixed.

> TL;DR: `git clone` → `./install.sh`. A background agent checks every 60s and
> reaps the stale `legacyScreenSaver` host so your screensaver comes back
> automatically.

---

## Does this match your problem?

This is for you if you're on macOS and seeing any of these:

- **XScreenSaver shows a black screen** / nothing renders / blank screen instead of the animation.
- The screensaver **preview is also black** in System Settings → Screen Saver (preview broken too).
- It **was working before** and randomly broke — often after **sleep/wake**, closing the lid, or an OS update.
- **No crash report**, no error dialog — it just silently fails to draw.
- "**macOS legacyScreenSaver crashed**" / not working / stopped working.
- Third-party `.saver` plugins (XScreenSaver, Aerial, Brooklyn, etc.) stopped animating.
- Screensaver works after you **manually kill a process / log out / reboot**, then breaks again later.

Search terms people use for this exact bug (you probably got here from one of these):
`xscreensaver black screen macos`, `legacyScreenSaver not working`,
`legacyScreenSaver crashed`, `macos screensaver black screen`,
`screensaver preview black`, `screensaver stopped working after sleep`,
`screensaver not rendering Sonoma / Sequoia / Tahoe`,
`macOS screen saver blank`, `.saver plugin not animating`,
`legacyScreenSaver.appex high cpu / stuck`.

> Note: this is **not** an XScreenSaver bug per se — XScreenSaver doesn't crash.
> The fault is in Apple's host process that runs third-party savers
> (`legacyScreenSaver`). See **Root cause** below.

---

## What actually goes wrong (root cause)

On modern macOS, third-party screensavers don't run on their own. They are loaded
as plugins inside an Apple-provided sandbox host process:

```
/System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex
```

When you select XScreenSaver (or any `.saver`), **that host** is what draws to the
screen — both the full-screen saver *and* the little preview in System Settings.

The failure mode: a **stale `legacyScreenSaver` host process** survives an
activation/sleep-wake cycle and wedges the render path. The process is still
alive, but it **paints nothing → black screen**. Because the same host drives the
preview, the preview goes black too. And because nothing actually *crashes*, you
get **no crash logs** — which is why this is so confusing to diagnose.

**The fix is simple once you know the cause:** kill the wedged host. launchd
respawns a clean one the next time the screensaver activates, and everything works
again. This project just automates that so you never have to think about it.

### Why "it didn't crash" but is still black

"Didn't crash" ≠ "rendered." The host can keep running while drawing nothing.
The reliable signal we use: **while you're actively using the Mac and not sitting
in the Screen Saver settings pane, there should be ZERO `legacyScreenSaver`
processes.** The host is supposed to exist only while the saver/preview is on
screen. Any lone host lingering while you're active is stale — so we reap it.

---

## How the guard decides (safe by design)

It runs every 60 seconds and **only ever kills a host when it is safe** — it never
interrupts a screensaver that's actually on your screen:

| `legacyScreenSaver` running | You are…                         | System Settings | Action      |
|-----------------------------|----------------------------------|-----------------|-------------|
| none                        | anything                         | anything        | nothing (healthy) |
| 1 or more                   | **active** (idle < saver delay)  | **closed**      | **reap → clean respawn** |
| 1 or more                   | idle past the saver delay        | —               | skip (a real saver may be on screen) |
| 1 or more                   | active                           | **open**        | skip (you're previewing — don't blink it) |
| 1 or more                   | idle time **unreadable**         | closed          | skip + `WARN` (fail safe — never risk killing a live saver) |
| 1 or more                   | saver set to **Never** (idleTime=0) | closed       | **reap** (no host is ever legitimate outside Settings) |

"Saver delay" = your configured `com.apple.screensaver idleTime` (defaults to 120s
when unreadable). All state reads are sanitized; anything garbled fails toward
*skip*, never toward *kill*. Process counting and kills are scoped to your user, so
the guard never touches another login session's saver.

### Bonus health check: sandbox container staging

There is a second, unrelated way the screensaver goes black that the reaper cannot
see: if `~/Library/ContainerManager/Staging` is (or points at) a missing directory,
the sandboxed `ScreenSaverEngine` quits ~20 ms after every launch — black screen,
no host process, nothing to reap, only an `MCMErrorDomain CREATE_STAGING_DIRECTORY`
line in the unified log. The guard now checks this path every tick; if it is a
symlink whose target vanished it restores the target and logs `HEALED`, otherwise
it logs a (throttled) `WARN` telling you what to fix.

---

## Install

```sh
git clone <this-repo>   # or just copy the folder
cd macos-screensaver-guard
./install.sh
```

That:
1. installs the script to `~/Library/Application Support/ScreensaverGuard/`,
2. installs a LaunchAgent to `~/Library/LaunchAgents/com.mistlight.screensaver-guard.plist`,
3. loads it (runs at login + every 60s) and verifies `last exit code = 0`.

No `sudo` required — it's a per-user agent.

## Uninstall

```sh
./uninstall.sh
```

## Test (no processes are killed)

```sh
./tests/test-guard.sh    # 10 dry-run decision cases, prints PASS/FAIL
```

---

## Verify / inspect

```sh
# What has the guard done?
tail -f ~/Library/Logs/screensaver-guard.log

# Is the agent loaded and healthy?
launchctl print gui/$(id -u)/com.mistlight.screensaver-guard | grep -E 'state|runs|last exit|interval'

# How many hosts are running right now? (0 is healthy while you're active)
pgrep -x legacyScreenSaver | wc -l
```

A healthy log line looks like:

```
2026-06-14 01:14:51 REAPED 1 stale legacyScreenSaver host(s); idle=0s -> clean respawn on next activation
```

## Manual recovery (one-liner)

If it ever goes black and you don't want to wait for the next 60s tick:

```sh
killall legacyScreenSaver
```

The screensaver will render cleanly on its next activation.

---

## Optional: battery black-screen (separate issue)

If the screen goes black specifically **on battery**, your battery display-sleep
timer may be firing at the same time as the screensaver. That's a power setting,
not this bug. To stop battery display-sleep (needs your password — the installer
does **not** do this):

```sh
sudo pmset -b displaysleep 0 sleep 20
```

(Keeps a 20-minute system-sleep safety net so a CPU-heavy saver doesn't drain the
battery forever. Use `sleep 0` to never sleep on battery.)

---

## Compatibility

- Built and verified on **macOS 26 (Tahoe)**, Apple Silicon. The mechanism
  (launchd LaunchAgent + `legacyScreenSaver` host) applies to **macOS 14 Sonoma,
  15 Sequoia, and 26 Tahoe** — anywhere third-party `.saver` plugins run inside
  `legacyScreenSaver`.
- Pure POSIX `sh` + built-in macOS tools (`pgrep`, `killall`, `ioreg`,
  `launchctl`, `defaults`). No dependencies, no Homebrew, nothing to compile.

## How it works under the hood

- `bin/screensaver-guard.sh` — the watchdog. Reads idle time from
  `ioreg -c IOHIDSystem` (`HIDIdleTime`) and the saver delay from
  `defaults -currentHost read com.apple.screensaver idleTime`, then applies the
  truth table above.
- `launchd/…plist.template` — the LaunchAgent (RunAtLoad + StartInterval 60,
  Background priority). The installer fills in the paths.
- The agent re-reads the script file every tick, so updating the script doesn't
  require reloading the agent.

## License

GPLv3
