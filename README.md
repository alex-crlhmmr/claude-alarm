# claude-code-alarm
Falling asleep between prompts? No more! Alarm bells whenever your task finishes.

An alarm bell for [Claude Code](https://code.claude.com). Walk away from a long
task and get woken up when it finishes — or when Claude is blocked waiting on you.

A single looping alarm sound and a desktop notification, plus a flashing taskbar
button on Windows. Clicking the notification brings the terminal to the front.

> **Windows** (`alarm.ps1`) and **macOS** (`alarm.sh`). See
> [Platform support](#platform-support).

## What it does

| Event | Trigger | Sound (Windows / macOS) | Gated? |
| --- | --- | --- | --- |
| `Stop` | Claude finishes a turn | `Alarm03.wav` / `Hero` | Only if the turn took **>60s** |
| `Notification` | Permission prompt or idle prompt | `Ring01.wav` / `Sosumi` | No — fires immediately |
| `UserPromptSubmit` | You type something | — | Kills any running alarm |

Short turns stay silent, so it only speaks up when you've actually walked away.
If Claude is blocked on you, there's no delay at all.

## Dismissing an alarm

Whichever is laziest:

- **Focus the Claude terminal** — stops in ~200ms (on macOS this is app-level, not
  per-window; see [Platform support](#platform-support))
- **Click the notification** — surfaces the terminal *and* stops the alarm
  (macOS: requires `terminal-notifier`, see below)
- **Type anything into Claude** — the `UserPromptSubmit` hook kills it
- **Do nothing** — it gives up after 20 seconds

Only one alarm ever runs. Starting a new one kills the previous, so they never stack.

## Install — Windows

1. Copy `alarm.ps1` to `~/.claude/hooks/alarm.ps1`.
2. Merge the `hooks` block from `settings.example.json` into `~/.claude/settings.json`,
   replacing `YOUR_USERNAME` with your own.

   Hook `args` are executed directly rather than through a shell, so `%USERPROFILE%`
   and `$HOME` are **not** expanded — the path must be absolute and literal.

3. Restart Claude Code, or just start a new turn. Verify with:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ~\.claude\hooks\alarm.ps1 -Action test-needs-input
   ```

If you already have hooks on these events, add these entries to the existing
`hooks` arrays rather than replacing them.

## Install — macOS

No dependencies: `afplay`, `osascript`, `lsappinfo` and bash 3.2 all ship with macOS.

1. Copy `alarm.sh` to `~/.claude/hooks/alarm.sh`.
2. Merge the `hooks` block from `settings.example.macos.json` into
   `~/.claude/settings.json`, replacing `YOUR_USERNAME` with your own.

   As on Windows, hook `args` are executed directly rather than through a shell,
   so `~` and `$HOME` are **not** expanded — the path must be absolute and literal.

3. Restart Claude Code, or just start a new turn. Verify with:

   ```bash
   bash ~/.claude/hooks/alarm.sh test-needs-input
   ```

### If you hear the alarm but never see a banner

macOS attributes `osascript` notifications to **Script Editor**, and on a stock
machine Script Editor is registered in Notification Center with "Allow
Notifications" **off**. There is no permission prompt to approve — the
notification is accepted, stored, and silently never displayed.

Fix it once, in System Settings → Notifications → **Script Editor** → **Allow
Notifications** on.

To confirm it is actually the cause rather than a mistimed banner, every
notification macOS accepts is logged with a `presented` flag:

```bash
python3 - <<'PY'
import sqlite3, os, datetime
p = os.path.expanduser("~/Library/Group Containers/group.com.apple.usernoted/db2/db")
c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
q = """SELECT datetime(r.delivered_date+978307200,'unixepoch','localtime'), r.presented
       FROM record r JOIN app a ON a.app_id=r.app_id
       WHERE a.identifier='com.apple.scripteditor2'
       ORDER BY r.delivered_date DESC LIMIT 5"""
for ts, shown in c.execute(q):
    print(ts, "presented" if shown else "NOT SHOWN (permission is off)")
PY
```

The *sound* is unaffected either way — `afplay` has no permission gate. Focus and
Do Not Disturb suppress the banner but not the sound.

Optional: `brew install terminal-notifier` to get click-the-notification-to-focus,
which plain `osascript` cannot do. The script uses it automatically if present, and
it sidesteps the problem above by registering its own bundle id, which does prompt
for permission normally.

## Configuration

Everything tunable is in one block at the top of `alarm.ps1` / `alarm.sh`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `$ENABLED` | `$true` | Master switch. `$false` silences everything without touching `settings.json`. |
| `$MIN_TURN_SECONDS` | `60` | "Done" alarms only fire for turns longer than this. |
| `$ALARM_SECONDS` | `20` | How long an alarm loops before giving up. |
| `$SOUND_DONE` | `Alarm03.wav` | Turn-finished sound. |
| `$SOUND_NEEDS_INPUT` | `Ring01.wav` | Blocked-on-you sound. |
| `$FOREGROUND_ARM_DELAY_MS` | `1500` | Grace period before focus-to-dismiss arms. See below. |
| `$POLL_INTERVAL_MS` | `150` | Dismiss responsiveness. |
| `$FLASH_TASKBAR` | `$true` | Flash the terminal's taskbar button. |
| `$STATE_RETENTION_DAYS` | `7` | Prune turn-timestamp files older than this. |

On macOS the equivalents are `ENABLED=1`, `SOUND_DONE='Hero'`,
`SOUND_NEEDS_INPUT='Sosumi'`, and there is no `FLASH_TASKBAR`. Two extra knobs:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SOUND_DIR` | `~/.claude/sounds` | Where your own sound files live. |
| `TERMINAL_BUNDLE_ID` | `''` | Terminal to treat as "the Claude window". Empty = auto-detect from `$TERM_PROGRAM`. |

Browse `C:\Windows\Media\` for other Windows sounds. `Alarm01`–`Alarm10` and
`Ring01`–`Ring10` are the attention-grabbing ones; `chimes`, `ding`, and `notify`
are gentler.

### Custom sounds (macOS)

`SOUND_DONE` and `SOUND_NEEDS_INPUT` resolve in this order:

1. an **absolute path** — used as-is
2. a **directory** under `~/.claude/sounds/` — a random file from it, re-rolled per
   alarm, so `SOUND_DONE='done'` with five files in `~/.claude/sounds/done/` rotates
3. a **name** under `~/.claude/sounds/` — first match, any extension
4. a **built-in** in `/System/Library/Sounds/`

`afplay` is CoreAudio, so `.aiff`, `.wav`, `.mp3`, `.m4a` and `.caf` all work with no
conversion. Built-ins on every Mac: `Basso` `Blow` `Bottle` `Frog` `Funk` `Glass`
`Hero` `Morse` `Ping` `Pop` `Purr` `Sosumi` `Submarine` `Tink`.

An unresolvable name falls back to a built-in and warns on stderr rather than going
silently quiet, since a silent alarm is indistinguishable from a hook that never fired.

### Why `$FOREGROUND_ARM_DELAY_MS` exists

Focus-to-dismiss doesn't arm for the first 1.5 seconds. Without the delay, an alarm
firing while you're already looking at the terminal would be killed instantly and
you'd hear nothing — technically consistent, but useless as a signal. Set it to `0`
if you'd rather have complete silence whenever you're already at the keyboard.

## Disabling

| Scope | Windows | macOS |
| --- | --- | --- |
| Silence alarms, keep hooks wired | `$ENABLED = $false` | `ENABLED=0` |
| Kill an alarm sounding right now | Type anything, or `alarm.ps1 -Action stop` | Type anything, or `alarm.sh stop` |
| Stop "done" only, keep "needs input" | `$MIN_TURN_SECONDS = 999999` | `MIN_TURN_SECONDS=999999` |
| Turn off every Claude Code hook | `"disableAllHooks": true` in `settings.json` | same |
| Remove entirely | Delete the hook entries and `alarm.ps1` | Delete the hook entries and `alarm.sh` |

## How it works

Two implementation details are non-obvious enough to be worth writing down, since
both are easy to get wrong when adapting this.

**Async hooks can't emit a `terminalSequence`.** Claude Code only parses hook stdout
for synchronous hooks; `async: true` hooks run detached and their stdout is discarded.
So a single async hook cannot deliver both a sound and a desktop notification. Each
event therefore registers two hooks: a synchronous `banner-*` hook that prints the
escape sequence and exits immediately, and an `async: true` hook that runs the sound
loop without blocking the session.

**Finding the terminal window can't go through the process tree.** Walking up from the
hook process yields `MainWindowHandle=0` at every level (`powershell`, `claude`, `cmd`),
and every Windows Terminal window shares a single process — so neither the process tree
nor the PID identifies the right window. Instead the `banner-*` hook stamps a marker
plus a short session id into the window title via OSC 0, and the alarm locates its own
window by searching for that marker. Matching falls back from exact session tag, to any
marker, to any window mentioning Claude; if nothing matches, the alarm still sounds and
only loses focus-dismissal.

The notification uses OSC 9 (allowlisted by Claude Code for Windows Terminal, ConEmu
and WezTerm) alongside a tray balloon, which is what renders the visible banner on
terminals that ignore OSC notifications.

### macOS specifics

**Frontmost-app detection avoids AppleScript.** The obvious way to ask what's focused
is `osascript -e 'tell application "System Events" ... frontmost ...'`, but System
Events needs an Automation permission grant — a hook firing in the background would
trip a TCC prompt, or silently fail forever once denied. `lsappinfo front` returns the
same answer with no permission of any kind, so focus-to-dismiss works out of the box.

**Killing an alarm needs an explicit `exit`.** A bash trap handler returns to where it
was interrupted rather than exiting. A `TERM` handler that only killed the child
`afplay` would let the poll loop notice the child was gone and start a *new* one — the
alarm surviving its own kill and leaking a player each round. The handler exits.

**The pid file is only cleared by its owner.** A newer alarm `TERM`s the old one and
then writes its own pid; the old one's trap can fire *after* that write, so an
unconditional `rm` would delete the newer alarm's registration and let the round after
it stack. Cleanup checks the file still contains its own pid first.

## Platform support

**Windows** (`alarm.ps1`) and **macOS** (`alarm.sh`).

macOS is dependency-free — `afplay`, `osascript`, `lsappinfo` and bash 3.2 all ship
with the OS — with two deliberate differences from Windows:

- **Focus-to-dismiss is app-level, not window-level.** Windows targets the exact
  terminal window via its title marker; macOS compares the frontmost *application*
  bundle id. Focusing any window of your terminal app dismisses the alarm.
- **Click-to-focus needs `terminal-notifier`.** `osascript` notifications carry no
  click action. Install `terminal-notifier` and the script uses it automatically.

Linux ports are still welcome — `paplay`/`aplay` against `/usr/share/sounds/`,
`notify-send`, terminal bell fallback.

The hook wiring is platform-agnostic; only the `command` and the script body change.

## Privacy

The only data written to disk is a Unix timestamp per Claude session, under
`.alarm-state/` (macOS: `~/.claude/hooks/.alarm-state/`, mode `0700`), used to decide
whether a turn ran long enough to be worth an alarm. Files are named by session id and
pruned after `STATE_RETENTION_DAYS`. Nothing is sent anywhere. `.alarm-state/` is
gitignored.

The session id is the only externally-supplied value either script handles. It arrives
on stdin from Claude Code and is stripped to `[A-Za-z0-9_-]` before use, because it
goes on to be interpolated into a terminal escape sequence and a filename. On macOS,
every string reaching AppleScript is passed through `argv` rather than interpolated
into the script source, so a quote in a title or body cannot become AppleScript.
