---
name: alarm-sound
description: Choose which sound claude-alarm plays when a turn finishes or when Claude is blocked on you. Use when the user wants to change, preview, add, or list alarm sounds.
---

# Choosing alarm sounds

Sets `SOUND_DONE` and `SOUND_NEEDS_INPUT` for `alarm.sh` by writing
`~/.claude/hooks/alarm.conf`. The alarm sources that file after its own
defaults, so changes apply to the next alarm with no restart.

Never ask which sound to play *while an alarm is firing* — the whole point is
that the user has walked away. Selection always happens here, ahead of time.

## Where sounds come from

| Location | What it is |
| --- | --- |
| `~/.claude/sounds/` | The user's own files. Empty by default. |
| `/System/Library/Sounds/` | macOS built-ins, always present. |

Built-ins: `Basso` `Blow` `Bottle` `Frog` `Funk` `Glass` `Hero` `Morse` `Ping`
`Pop` `Purr` `Sosumi` `Submarine` `Tink`. Defaults are `Hero` for a finished
turn and `Sosumi` for blocked-on-you.

`afplay` is CoreAudio, so `.wav` `.aiff` `.mp3` `.m4a` `.caf` all work with no
conversion. Prefer `.wav` or `.aiff`: they are uncompressed and start instantly,
where a compressed file has a short decode delay that is audible on a sound
meant to be a prompt alert. Keep clips to **1–4 seconds** — they are looped for
up to `ALARM_SECONDS`, so anything longer never reaches its end.

## Doing it

1. **List what is available.**

   ```bash
   ls -1 ~/.claude/sounds/ 2>/dev/null
   ls -1 /System/Library/Sounds/ | sed 's/\.aiff$//'
   ```

   If `~/.claude/sounds/` is missing or empty, say so and offer the built-ins —
   an empty folder is the normal state, not a problem to fix.

2. **Offer a choice with AskUserQuestion**, one question per event (finished
   turn, blocked-on-you) so they can differ. Both should be easy to tell apart
   by ear; suggest a distinct pair rather than two similar tones.

3. **Preview before committing** when the user is unsure. This plays the actual
   file, which is more useful than describing it:

   ```bash
   afplay ~/.claude/sounds/NAME.wav      # or
   afplay /System/Library/Sounds/Hero.aiff
   ```

4. **Write the choice** to `~/.claude/hooks/alarm.conf`, preserving any other
   settings already in that file. It is shell, so values are quoted:

   ```bash
   SOUND_DONE='Hero'
   SOUND_NEEDS_INPUT='Sosumi'
   ```

   A bare name is resolved against `~/.claude/sounds/` first, then
   `/System/Library/Sounds/`. An absolute path is used as-is. A **directory
   name** under `~/.claude/sounds/` picks a random file from it per alarm — use
   that when the user wants rotation rather than one fixed sound.

5. **Confirm** by firing a real alarm, not just by reporting success:

   ```bash
   bash ~/.claude/hooks/alarm.sh test-needs-input
   ```

   Mention it runs for up to 20 seconds and that focusing the terminal stops it.

## Adding new sounds

Create the folder if needed and tell the user to drop files in:

```bash
mkdir -p ~/.claude/sounds
open ~/.claude/sounds
```

If a chosen name cannot be resolved the alarm falls back to a built-in and warns
on stderr rather than going silent — a silent alarm is indistinguishable from a
hook that never fired, so never leave the user believing a broken name is fine.
