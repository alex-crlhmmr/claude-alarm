# claude-code-alarm

An alarm bell for [Claude Code](https://code.claude.com). Walk away from a long
task and get woken up when it finishes — or when Claude is blocked waiting on you.

A single looping alarm sound, a desktop notification, and a flashing taskbar
button. Clicking the notification brings the right terminal window to the front.

> **Windows only.** See [Platform support](#platform-support) before you invest.

## What it does

| Event | Trigger | Sound | Gated? |
| --- | --- | --- | --- |
| `Stop` | Claude finishes a turn | `Alarm03.wav` (rising alarm) | Only if the turn took **>60s** |
| `Notification` | Permission prompt or idle prompt | `Ring01.wav` (phone ring) | No — fires immediately |
| `UserPromptSubmit` | You type something | — | Kills any running alarm |

Short turns stay silent, so it only speaks up when you've actually walked away.
If Claude is blocked on you, there's no delay at all.

## Dismissing an alarm

Whichever is laziest:

- **Focus the Claude terminal window** — stops in ~200ms
- **Click the tray notification** — surfaces the terminal *and* stops the alarm
- **Type anything into Claude** — the `UserPromptSubmit` hook kills it
- **Do nothing** — it gives up after 20 seconds

Only one alarm ever runs. Starting a new one kills the previous, so they never stack.

## Install

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

## Configuration

Everything tunable is in one block at the top of `alarm.ps1`:

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

Browse `C:\Windows\Media\` for other sounds. `Alarm01`–`Alarm10` and `Ring01`–`Ring10`
are the attention-grabbing ones; `chimes`, `ding`, and `notify` are gentler.

### Why `$FOREGROUND_ARM_DELAY_MS` exists

Focus-to-dismiss doesn't arm for the first 1.5 seconds. Without the delay, an alarm
firing while you're already looking at the terminal would be killed instantly and
you'd hear nothing — technically consistent, but useless as a signal. Set it to `0`
if you'd rather have complete silence whenever you're already at the keyboard.

## Disabling

| Scope | How |
| --- | --- |
| Silence alarms, keep hooks wired | `$ENABLED = $false` |
| Kill an alarm sounding right now | Type anything, or run `alarm.ps1 -Action stop` |
| Stop "done" only, keep "needs input" | `$MIN_TURN_SECONDS = 999999` |
| Turn off every Claude Code hook | `"disableAllHooks": true` in `settings.json` |
| Remove entirely | Delete the hook entries and `alarm.ps1` |

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

## Platform support

**Windows only right now.** It depends on `System.Media.SoundPlayer`, WinForms
`NotifyIcon`, and Win32 `user32.dll` calls for window targeting.

The equivalent primitives exist elsewhere and ports are welcome:

- **macOS** — `afplay /System/Library/Sounds/Sosumi.aiff`, `osascript -e 'display notification'`
- **Linux** — `paplay`/`aplay` against `/usr/share/sounds/`, `notify-send`, terminal bell fallback

The hook wiring in `settings.example.json` is platform-agnostic; only the `command`
and the script body need replacing.

## Privacy

The only data written to disk is a Unix timestamp per Claude session, under
`.alarm-state/`, used to decide whether a turn ran long enough to be worth an alarm.
Files are named by session id and pruned after `$STATE_RETENTION_DAYS`. Nothing is
sent anywhere. `.alarm-state/` is gitignored.
