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
  (macOS: requires [claude-notify](#notification-center-on-macos-15))
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

### Notification Center on macOS 15

On some Macs a notification is accepted, recorded in Notification Center's
database, its sound plays, and it is **never displayed**. No prompt to approve,
no error, nothing in any log. It affects `osascript` and `terminal-notifier`
alike — see [terminal-notifier#312](https://github.com/julienXX/terminal-notifier/issues/312)
and [Apple's own thread](https://discussions.apple.com/thread/255766920). The
usual community fixes (the mirroring toggle, alert style, `-sender`, restarting
`usernoted`) work for some people and not others; on the machine this port was
developed against, none of them did.

What does work there is [claude-notify](https://github.com/armandsalle/claude-notify),
a menu-bar daemon. Install it and `alarm.sh` uses it automatically:

```bash
git clone https://github.com/armandsalle/claude-notify && cd claude-notify
./build.sh && cp -r .build/release/ClaudeNotify.app /Applications/
codesign --force --deep --sign - /Applications/ClaudeNotify.app
```

Two things about it are worth knowing, because both cost hours to work out:

- **Do not run it from a LaunchAgent.** Clicking a banner is only routed back to
  the process that *posted* it. Under launchd the CLI relays to a separate daemon
  and the click has nothing to route to, which fails with "The application is not
  open anymore" — the banner appears and the click is dead. `alarm.sh` therefore
  backgrounds it and never kills it.
- **A transient process cannot work at all.** Anything that posts a notification
  and exits can show a banner but can never handle a click. This is why the
  working implementations are all daemons; it is not a flag you are missing.

#### Clicking the banner lands on the right tab

Activating an app restores whatever tab was last focused in it, which is the
wrong one whenever Claude is in a background tab. `focus-tab/` fixes that:

```bash
./focus-tab/build.sh
```

`alarm.sh` then hands the click to that helper instead of to the terminal, and
it selects the tab by **tty**. Not by window title — Claude Code overwrites the
title with its own session name, so the `(!) Claude` marker the banner hook
writes is not reliably there to match on. A tty is exact and cannot collide,
and Terminal exposes it per tab.

It needs Automation permission for Terminal, requested once on the first click.
Decline it and clicks still raise the terminal, just not the specific tab.

**Terminal.app only**, enforced by `FOCUS_HELPER_TERMINALS`. Everywhere else the
click activates the app exactly as before, which is the pre-existing behaviour
rather than a regression:

| Terminal | Click behaviour |
| --- | --- |
| Terminal.app | lands on the exact tab |
| iTerm2 | activates the app |
| VS Code | activates the app |
| Ghostty / WezTerm / others | activates the app |

iTerm2 is scriptable and could be supported — it exposes tabs through a different
object model, so it needs its own script rather than a tweak to this one.

**VS Code cannot be supported at this layer.** Its integrated terminals are real
ptys with real ttys, but VS Code exposes no AppleScript interface to enumerate or
focus them; there is no supported way to say "focus terminal 3 in window 2" from
outside the editor. That needs a VS Code extension. The same applies to several
terminals inside one tab: our match is per tab, and split panes are not
addressable this way even in Terminal.app.

> One trap if you adapt this: `set index of window w to 1` reorders AppleScript's
> own window list without raising the window on screen, so the script reports
> success while you land on whatever was visually on top. `set frontmost of
> window w to true` is what actually raises it.

#### Custom banner icon

A notification shows the icon of the app that posted it, so a custom icon goes
into claude-notify's bundle:

```bash
./install-notifier-icon.sh path/to/image.png
```

Any format `sips` reads works, and non-square input is padded rather than
cropped. macOS caches icons hard: if the old one persists, the script's own
advice applies — it restarts the daemon, but you may also need
`killall Dock NotificationCenter usernoted`, and occasionally a logout.

Because this writes into `/Applications/ClaudeNotify.app`, **updating
claude-notify wipes it**. Re-run the script; that is why it is a script.

If you skip it entirely, the alarm still works — `RAISE_TERMINAL_AFTER`
(default 8s) brings the terminal to the front if you haven't reacted:

```
alarm fires -> sound loops -> 8s pass with no reaction -> terminal comes to front
```

Raising goes through LaunchServices, needs no permission of any kind, and is
harder to miss than a banner even where banners work — the window physically
appears in front of whatever you were looking at. It also dismisses the alarm on
its own, since the terminal becoming frontmost is exactly what focus-to-dismiss
waits for. Set it to `0` if you'd rather it never steal focus.

`SPEAK=1` additionally says the message out loud, which carries from another room.
Neither needs permission, and both work with the notification silently broken.

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

`brew install terminal-notifier` is worth trying — the script uses it automatically
if present — but do not expect it to fix this. It is subject to the same failure,
and on the machine this port was developed against it never displayed a banner
either. [claude-notify](#notification-center-on-macos-15) is what worked.

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
| `ALARM_CONF` | `~/.claude/hooks/alarm.conf` | Sourced after the defaults; overrides any of them. Written by `/alarm-sound`. |
| `TERMINAL_BUNDLE_ID` | `''` | Terminal to treat as "the Claude window". Empty = auto-detect. |
| `RAISE_TERMINAL_AFTER` | `8` | Bring the terminal to the front after this many unacknowledged seconds. `0` disables. |
| `CLAUDE_NOTIFY` | `/Applications/ClaudeNotify.app/…` | Path to claude-notify. Used automatically when present. |
| `SPEAK` | `0` | Say the alert out loud. |
| `SPEAK_VOICE` | `''` | Voice for `SPEAK`, e.g. `Samantha`. Empty = system default. |

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

Prefer `.wav` or `.aiff`. They are uncompressed and start instantly, where a
compressed file has a short decode delay that is audible on a sound meant to be a
prompt alert. Keep clips to **1–4 seconds** — they loop for up to `ALARM_SECONDS`,
so a longer one never reaches its end.

### Choosing sounds without editing the script

`alarm.sh` sources `~/.claude/hooks/alarm.conf` after its own defaults, so anything
set there wins and updating the script does not overwrite your choices:

```bash
SOUND_DONE='Hero'
SOUND_NEEDS_INPUT='Submarine'
```

It is sourced, so it is shell rather than an ini file — quoted values, no colons.

The bundled `alarm-sound` skill writes that file for you. Install it with:

```bash
mkdir -p ~/.claude/skills/alarm-sound
cp skills/alarm-sound/SKILL.md ~/.claude/skills/alarm-sound/
```

Then `/alarm-sound` lists what is in `~/.claude/sounds/` alongside the built-ins,
previews them, and saves the pair you pick. It deliberately does the choosing
ahead of time rather than prompting mid-alarm — an alarm that asks a question is
useless to someone who has walked away from the keyboard.

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

**`$TERM_PROGRAM` cannot be trusted to identify the terminal.** It is empty in the
hook environment on at least some installs, and an empty bundle id silently
disables both focus-to-dismiss and the raise — the alarm still sounds, so nothing
looks broken. The fallback walks the process ancestry for enclosing `.app`
bundles and takes the **outermost** one. That ordering matters: the chain runs

```
zsh -> ClaudeCode.app -> claude -> login -> Terminal.app
```

so the innermost `.app` is Claude Code's own helper bundle (`com.anthropic.claude-code`),
while the terminal window you actually want to raise sits furthest from you.

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
- **Click-to-focus needs a notification daemon.** `osascript` notifications carry no
  click action at all, and a process that posts a notification and exits can never
  handle a click regardless of how it posts it. Install
  [claude-notify](#notification-center-on-macos-15) and the script uses it
  automatically; without it you still get the sound and the raise.

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
