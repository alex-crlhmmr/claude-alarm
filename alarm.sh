#!/bin/bash
#
# Alarm-bell notification system for Claude Code hooks -- macOS port of alarm.ps1.
#
# Plays a looping, hard-to-ignore sound when a long turn finishes ("done") or
# when Claude is blocked waiting on you ("needs-input").
#
# Dismissal, in order of convenience:
#   * Focus the Claude terminal app          -> alarm stops
#   * Click the notification                 -> terminal surfaces, alarm stops
#                                               (requires terminal-notifier)
#   * Type anything into Claude              -> UserPromptSubmit kills it
#   * Wait $ALARM_SECONDS                    -> gives up on its own
#
# Only one alarm ever runs at a time; starting a new one kills the previous.
#
# Actions:
#   start                : record turn start timestamp + kill any running alarm
#   stop                 : kill any running alarm (you're awake)
#   done                 : fire the "done" alarm, gated on turn duration
#   needs-input          : fire the "needs input" alarm, no gate
#   banner-done          : print terminalSequence JSON for "done" (gated)
#   banner-needs-input   : print terminalSequence JSON for "needs input"
#   test-done            : fire "done" alarm ignoring the duration gate
#   test-needs-input     : fire "needs input" alarm
#
# Targets bash 3.2 (the version Apple ships) -- no bash 4+ syntax.

# ==========================================================================
#  CONFIG -- edit these
# ==========================================================================

# Master switch. Set to 0 to silence every alarm without touching settings.json.
ENABLED=1

# A "done" alarm only fires if the turn took longer than this many seconds.
# Short turns stay silent. Does NOT apply to "needs-input" alarms.
MIN_TURN_SECONDS=60

# Maximum time an alarm keeps looping before giving up, in seconds.
ALARM_SECONDS=20

# Sounds. Each value is resolved in this order:
#   1. absolute path to a file          -> used as-is
#   2. a directory in ~/.claude/sounds/ -> a random file from it, per alarm
#   3. a name in ~/.claude/sounds/      -> first matching file, any extension
#   4. a name in /System/Library/Sounds -> the macOS built-in of that name
# afplay is CoreAudio, so .aiff / .wav / .mp3 / .m4a / .caf all work.
#
# Built-ins available on every Mac: Basso Blow Bottle Frog Funk Glass Hero
# Morse Ping Pop Purr Sosumi Submarine Tink
SOUND_DONE='Hero'
SOUND_NEEDS_INPUT='Sosumi'

# Where your own sound files live. Drop mp3/wav/aiff in here and name them above.
SOUND_DIR="$HOME/.claude/sounds"

# Focusing the Claude terminal stops the alarm. This is the delay before that
# watcher arms, so an alarm that fires while you are already at the keyboard
# still makes a noise instead of being silently swallowed. Set to 0 to have
# the alarm never sound while the terminal is already focused.
FOREGROUND_ARM_DELAY_MS=1500

# How often the dismiss-watcher polls.
POLL_INTERVAL_MS=150

# Bundle id of the terminal to treat as "the Claude window". Empty = auto-detect
# from $TERM_PROGRAM. Set explicitly if auto-detection picks the wrong app.
TERMINAL_BUNDLE_ID=''

# Escalation: if the alarm goes unacknowledged this many seconds, bring the
# terminal to the front. 0 disables.
#
# This exists because Notification Center cannot be relied on. On macOS 15 a
# notification is routinely accepted, recorded, and never displayed -- sound
# plays, no banner, nothing to approve, no error anywhere. It affects osascript
# and terminal-notifier alike (julienXX/terminal-notifier#312). Raising a window
# goes through LaunchServices instead, needs no permission of any kind, and is
# harder to miss than a banner even when banners do work.
#
# Raising also dismisses the alarm on its own: the terminal becomes frontmost,
# which is exactly what the focus watcher below is waiting for.
RAISE_TERMINAL_AFTER=0

# Speak the alert once when the alarm starts. Also needs no permission, and
# carries from another room. 0 disables.
SPEAK=0
SPEAK_VOICE=''

# Optional: claude-notify, https://github.com/armandsalle/claude-notify
#
# On macOS 15 this is often the only thing that shows a banner at all, and the
# only one that can act on a click -- see the README section on Notification
# Center. Install it and this picks it up automatically; leave it uninstalled
# and the alarm falls back to terminal-notifier, then osascript, then to the
# sound and the raise, which need no notification system at all.
CLAUDE_NOTIFY='/Applications/ClaudeNotify.app/Contents/MacOS/ClaudeNotify'

# Optional: focus the exact terminal tab Claude is running in when you click the
# banner, rather than just bringing the terminal app forward.
#
# Activating an app restores whatever tab was last focused there, which is the
# wrong one whenever you left Claude in a background tab. claude-notify can only
# activate an app on click, not run a command, so the click points at a tiny
# helper app whose whole job is to select the right tab and quit.
#
# The tab is matched on tty, not on window title: Claude Code overwrites the
# title with its own session name, so the OSC 0 marker the banner hook writes is
# not reliably there to match against. tty is exact and cannot collide.
#
# Build it with focus-tab/build.sh. Needs Automation permission for your
# terminal, granted once on first click. Unset to just activate the app.
#
# Terminal.app only, and the guard below enforces that. The helper scripts
# Terminal specifically; it cannot address tabs in anything else. iTerm2 is
# scriptable but exposes tabs through a different object model, and VS Code's
# integrated terminals -- real ptys with real ttys -- are not exposed to
# AppleScript at all, so there is no way to focus one from outside the editor.
# Anywhere but Terminal.app the click just activates the app, as before.
FOCUS_HELPER_APP="$HOME/Applications/FocusClaudeTab.app"
FOCUS_HELPER_BUNDLE='com.claudealarm.focustab'
#
# VS Code is deliberately NOT in this list. It has no AppleScript dictionary, and
# the Accessibility fallback does not work either: with Accessibility granted and
# working, its main process reports zero windows, because Electron only publishes
# an AX tree when it detects a screen reader. There is nothing to enumerate or
# raise. Routing it through the helper would achieve exactly what activating the
# app already does. The helper still handles the generic case, so another
# non-scriptable terminal that does publish windows can be added here.
FOCUS_HELPER_TERMINALS='com.apple.Terminal'

# Last-resort fallback: a clickable dialog window with a button that takes you to
# the terminal. Off by default -- it is an ugly modal box, not a notification.
#
# Turn it on only if you get no banner at all. A dialog is an ordinary window
# owned by the terminal app rather than a notification, so it still renders on
# machines where Notification Center refuses to display anything.
DIALOG=0
DIALOG_BUTTON='Go to terminal'

# Turn-timestamp files are written one per Claude session and are worthless once
# the session ends. Anything older than this many days is pruned on next use.
STATE_RETENTION_DAYS=7

# Text shown in the notification and the terminal title bar.
TITLE_DONE='Claude Code'
BODY_DONE='Turn finished — ready for you.'
TITLE_NEEDS_INPUT='Claude Code'
BODY_NEEDS_INPUT='Waiting on you to continue.'

# Marker written into the terminal title by the banner hooks. Cosmetic on macOS
# (unlike Windows, the alarm does not need it to find the window).
TITLE_MARKER='(!) Claude'

# ==========================================================================
#  End of config
# ==========================================================================

# Per-machine overrides, sourced after the defaults so it can change any of
# them. Written by the /alarm-sound command; edit it by hand if you prefer.
# Keeping choices here rather than in this file means updating the script does
# not overwrite your settings.
#
# It is sourced, so it is shell, not an ini file -- `SOUND_DONE='chime'`, not
# `SOUND_DONE: chime`. It runs with your privileges like any other hook.
ALARM_CONF="${ALARM_CONF:-$HOME/.claude/hooks/alarm.conf}"
[ -f "$ALARM_CONF" ] && . "$ALARM_CONF"

SCRIPT_NAME=$(basename "$0")
STATE_DIR="$HOME/.claude/hooks/.alarm-state"
PID_FILE="$STATE_DIR/alarm.pid"

init_state_dir() {
  # 0700: the state dir holds session ids, and a world-writable state path
  # would be a symlink-swap target on a multi-user machine.
  [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
  chmod 700 "$STATE_DIR" 2>/dev/null
}

now_s() { date +%s; }

# Claude Code hands each hook a JSON blob on stdin. session_id keeps concurrent
# Claude sessions from clobbering each other's turn timestamps, and gives each
# window a distinct title marker.
#
# Extracted with grep rather than a JSON parser so the script stays dependency
# free (no jq, no python3), and hard-sanitised to [A-Za-z0-9_-] on the way out.
# That sanitising is load-bearing: this is the only attacker-influenced value in
# the script, and it goes on to be interpolated into a terminal escape sequence.
# stdin can only be consumed once, and more than one field is wanted from it,
# so it is slurped a single time and reused.
#
# Called explicitly from the dispatch below, and only for the actions Claude Code
# actually pipes JSON to. It must not be called lazily from a getter: "cat" on a
# stdin that is open but never delivers EOF blocks forever, and a -t 0 check does
# not catch that -- a pipe is not a tty whether or not anything is coming. Hooks
# are fine because Claude Code writes its JSON and closes, but a manual or
# scripted run with an inherited pipe would hang the alarm indefinitely.
HOOK_JSON=''
HOOK_JSON_READ=''
read_hook_stdin() {
  [ -n "$HOOK_JSON_READ" ] && return 0
  HOOK_JSON_READ=1
  [ -t 0 ] || HOOK_JSON=$(cat 2>/dev/null)
  return 0
}

get_session_key() {
  local key=''
  key=$(printf '%s' "$HOOK_JSON" \
    | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/' \
    | tr -cd 'A-Za-z0-9_-')
  [ -n "$key" ] || key='default'
  printf '%s' "$key"
}

# The working directory of the session, used to pick the right editor window --
# its title carries the folder name. Newlines, quotes and backslashes are
# stripped: this is attacker-influenced like session_id, and it is written to a
# file that a helper app reads back line by line.
get_cwd() {
  local c
  c=$(printf '%s' "$HOOK_JSON" \
    | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed 's/.*"\([^"]*\)"$/\1/' \
    | tr -d '\\"' | tr -d '\n\r')
  # Falls back to the working directory, which is what a test run wants and is
  # correct for a hook too -- hooks inherit the session's cwd.
  [ -n "$c" ] || c=$PWD
  printf '%s' "$c"
}

# Short, human-tolerable window tag: first 8 chars of the session id.
get_session_tag() { printf '%s' "$(printf '%s' "$1" | cut -c1-8)"; }

turn_file() { printf '%s' "$STATE_DIR/turn-$1.txt"; }

# One turn file is created per Claude session and nothing else ever removes them,
# so without this they accumulate indefinitely. Session ids are also the only
# identifying data this script stores, so expiring them is worth doing on its own.
remove_stale_turn_files() {
  find "$STATE_DIR" -maxdepth 1 -name 'turn-*.txt' -type f \
    -mtime "+$STATE_RETENTION_DAYS" -delete 2>/dev/null
}

# --------------------------------------------------------------------------
#  Sound resolution
# --------------------------------------------------------------------------

pick_random_from_dir() {
  local dir="$1" n i
  local files=()
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f \
             \( -iname '*.aiff' -o -iname '*.aif' -o -iname '*.wav' \
                -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.caf' \) 2>/dev/null)
  n=${#files[@]}
  [ "$n" -eq 0 ] && return 1
  # Not $RANDOM: bash 3.2 seeds it from the pid, so the first draw in a freshly
  # spawned process tracks sequential pids -- and every hook invocation is a
  # fresh process. That produced the same "random" file 5 times out of 6.
  i=$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -cd '0-9')
  [ -n "$i" ] || i=$$
  i=$(( i % n ))
  printf '%s' "${files[$i]}"
}

resolve_sound() {
  local val="$1" match

  case "$val" in
    /*) [ -f "$val" ] && { printf '%s' "$val"; return 0; } ;;
  esac

  if [ -d "$SOUND_DIR/$val" ]; then
    match=$(pick_random_from_dir "$SOUND_DIR/$val") && {
      printf '%s' "$match"; return 0; }
  fi

  [ -f "$SOUND_DIR/$val" ] && { printf '%s' "$SOUND_DIR/$val"; return 0; }

  match=$(find "$SOUND_DIR" -maxdepth 1 -type f -name "$val.*" 2>/dev/null | head -1)
  [ -n "$match" ] && { printf '%s' "$match"; return 0; }

  [ -f "/System/Library/Sounds/$val.aiff" ] && {
    printf '%s' "/System/Library/Sounds/$val.aiff"; return 0; }

  return 1
}

# --------------------------------------------------------------------------
#  Frontmost-app detection
# --------------------------------------------------------------------------
#
# lsappinfo is used rather than the more familiar
#   osascript -e 'tell application "System Events" ... frontmost ...'
# because System Events requires an Automation permission grant, and a hook
# firing in the background would trip a TCC prompt (or silently fail once
# denied). lsappinfo needs no permissions at all.

detect_terminal_bundle_id() {
  [ -n "$TERMINAL_BUNDLE_ID" ] && { printf '%s' "$TERMINAL_BUNDLE_ID"; return; }

  case "$TERM_PROGRAM" in
    Apple_Terminal) printf 'com.apple.Terminal';    return ;;
    iTerm.app)      printf 'com.googlecode.iterm2'; return ;;
    vscode)         printf 'com.microsoft.VSCode';  return ;;
    ghostty)        printf 'com.mitchellh.ghostty'; return ;;
    WezTerm)        printf 'com.github.wez.wezterm';return ;;
    Hyper)          printf 'co.zeit.hyper';         return ;;
    Alacritty)      printf 'org.alacritty';         return ;;
    WarpTerminal)   printf 'dev.warp.Warp-Stable';  return ;;
  esac

  # TERM_PROGRAM is not always exported into the hook environment -- it is empty
  # for hooks spawned by Claude Code on at least some installs, which silently
  # disabled both focus-dismissal and the raise. Fall back to walking the
  # process ancestry for enclosing .app bundles.
  #
  # Take the OUTERMOST match, not the first: the chain runs
  #   zsh -> ClaudeCode.app -> claude -> login -> Terminal.app
  # so the innermost .app is Claude Code's own helper bundle, while the terminal
  # window we actually want to raise sits furthest from us.
  local pid cmd appdir id last=''
  pid=$$
  while [ "${pid:-0}" -gt 1 ]; do
    cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
    case "$cmd" in
      *.app/Contents/MacOS/*)
        appdir="${cmd%%.app/*}.app"
        id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
               "$appdir/Contents/Info.plist" 2>/dev/null)
        [ -n "$id" ] && last="$id"
        ;;
    esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  done
  printf '%s' "$last"
}

front_bundle_id() {
  local asn
  asn=$(lsappinfo front 2>/dev/null) || return 1
  [ -n "$asn" ] || return 1
  lsappinfo info -only bundleid "$asn" 2>/dev/null \
    | sed 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/'
}

# --------------------------------------------------------------------------
#  Notification
# --------------------------------------------------------------------------
#
# Every string reaches AppleScript through argv, never through the script
# source. Interpolating into -e text would make any quote character in a title
# or body -- including anything derived from hook stdin -- an AppleScript
# injection. Passing argv removes that class of bug outright.

# The tty of the terminal this session is attached to. Hook processes have no
# controlling terminal of their own, so walk up until a parent does -- the
# nearest one is the shell Claude runs in, which is the tab we want focused.
our_tty() {
  local pid t
  pid=$$
  while [ "${pid:-0}" -gt 1 ]; do
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "??" ]; then printf '/dev/%s' "$t"; return 0; fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}

notify() {
  local title="$1" body="$2" bundle="$3" target="$3" tty=''

  # Hand the click to the tab-focus helper when it is installed, leaving the
  # tty where it can find it. Falls back to activating the terminal app.
  case " $FOCUS_HELPER_TERMINALS " in
    *" $bundle "*)
      if [ -n "$FOCUS_HELPER_APP" ] && [ -d "$FOCUS_HELPER_APP" ]; then
        tty=$(our_tty)
        {
          printf 'bundle=%s\n' "$bundle"
          printf 'tty=%s\n'    "$tty"
          printf 'cwd=%s\n'    "$(get_cwd)"
        } > "$STATE_DIR/focus-target" 2>/dev/null
        chmod 600 "$STATE_DIR/focus-target" 2>/dev/null
        target="$FOCUS_HELPER_BUNDLE"
      fi
      ;;
  esac

  # Preferred: claude-notify. Backgrounded and deliberately never killed --
  # clicking a banner is only routed back while the process that posted it is
  # still alive, so reaping it is what produces "The application is not open
  # anymore". It is a menu-bar daemon and later alarms reuse the same instance.
  if [ -n "$CLAUDE_NOTIFY" ] && [ -x "$CLAUDE_NOTIFY" ]; then
    if [ -n "$target" ]; then
      "$CLAUDE_NOTIFY" -m "$body" -t "$title" -a "$target" >/dev/null 2>&1 &
    else
      "$CLAUDE_NOTIFY" -m "$body" -t "$title" >/dev/null 2>&1 &
    fi
    return
  fi

  if command -v terminal-notifier >/dev/null 2>&1; then
    # terminal-notifier gets us click-to-focus, which osascript cannot do.
    #
    # -sender is not cosmetic on macOS 15. Both terminal-notifier's own bundle
    # id and the Script Editor identity osascript borrows are refused a banner
    # there: the notification is accepted and recorded, its sound plays, and it
    # is never presented. Sending as an app that already holds notification
    # permission -- the terminal Claude is running in -- is what makes it
    # render. See julienXX/terminal-notifier#312.
    # No -group. Grouping makes a repeat send *replace* the existing
    # notification in that group, and a replacement is not re-presented -- the
    # record's timestamp updates and no banner ever appears. It looked like a
    # permission problem and was not one.
    if [ -n "$bundle" ]; then
      terminal-notifier -sender "$bundle" -activate "$target" \
        -title "$title" -message "$body  (click to open)" >/dev/null 2>&1 &
    else
      terminal-notifier -title "$title" -message "$body" >/dev/null 2>&1 &
    fi
    return
  fi

  osascript \
    -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv)' \
    -e 'end run' \
    "$body" "$title" >/dev/null 2>&1 &
}

# --------------------------------------------------------------------------
#  Alarm lifecycle
# --------------------------------------------------------------------------

# Kill a previously running alarm so alarms never stack.
# Guards against PID reuse by confirming the process is actually this script.
stop_running_alarm() {
  [ -f "$PID_FILE" ] || return 0
  local old_pid cmd
  old_pid=$(head -1 "$PID_FILE" 2>/dev/null | tr -cd '0-9')
  if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ]; then
    # Matching on our own basename rather than a hardcoded "alarm.sh" so the
    # guard keeps working if the script is installed under another name.
    cmd=$(ps -p "$old_pid" -o command= 2>/dev/null)
    case "$cmd" in
      *"$SCRIPT_NAME"*) kill -TERM "$old_pid" 2>/dev/null ;;
    esac
  fi
  rm -f "$PID_FILE" 2>/dev/null
  return 0
}

# If we have no timestamp (fresh install, resumed session) stay silent rather
# than fire a spurious alarm.
turn_was_long() {
  local f start elapsed
  f=$(turn_file "$1")
  [ -f "$f" ] || return 1
  start=$(head -1 "$f" 2>/dev/null | tr -cd '0-9')
  [ -n "$start" ] || return 1
  elapsed=$(( $(now_s) - start ))
  [ "$elapsed" -ge "$MIN_TURN_SECONDS" ]
}

AF_PID=''

# Only clear the pid file if it is still ours. A newer alarm TERMs us and then
# writes its own pid; our trap can fire after that write, and an unconditional
# rm would delete the newer alarm's registration. The alarm after that would
# then find no pid file, fail to stop it, and the two would sound together.
remove_own_pid_file() {
  local cur
  cur=$(head -1 "$PID_FILE" 2>/dev/null | tr -cd '0-9')
  [ "$cur" = "$$" ] && rm -f "$PID_FILE" 2>/dev/null
  return 0
}

SAY_PID=''
DIALOG_PID=''
CLICK_FILE=''
cleanup() {
  [ -n "$AF_PID" ] && kill "$AF_PID" 2>/dev/null
  [ -n "$SAY_PID" ] && kill "$SAY_PID" 2>/dev/null
  # Kill the osascript child too, not just the subshell wrapping it, or the
  # dialog outlives the alarm that put it up.
  if [ -n "$DIALOG_PID" ]; then
    pkill -P "$DIALOG_PID" 2>/dev/null
    kill "$DIALOG_PID" 2>/dev/null
  fi
  [ -n "$CLICK_FILE" ] && rm -f "$CLICK_FILE" 2>/dev/null
  remove_own_pid_file
}

# Put the dialog up in the background, writing osascript's result to a file the
# poll loop watches. osascript is backgrounded directly rather than wrapped in a
# subshell so DIALOG_PID is the osascript itself: killing it closes the dialog,
# where killing a wrapper left the dialog on screen after the alarm ended.
#
# osascript prints "gave up:false" when a button was actually pressed and
# "gave up:true" when the dialog timed out, which is how a click is told apart
# from being ignored.
#
# The dialog is owned by the terminal app via "tell application id" so it renders
# as that app's own window -- an ordinary window, not a notification, which is
# why it appears on machines where no banner ever does. Strings go through argv,
# never interpolated into the AppleScript source.
start_dialog() {
  local title="$1" body="$2" bundle="$3" secs="$4" out="$5"
  osascript \
    -e 'on run argv' \
    -e 'tell application id (item 3 of argv) to display dialog (item 1 of argv) with title (item 2 of argv) buttons {(item 5 of argv)} default button 1 giving up after (item 4 of argv as integer)' \
    -e 'end run' \
    "$body" "$title" "$bundle" "$secs" "$DIALOG_BUTTON" > "$out" 2>/dev/null &
  DIALOG_PID=$!
}

# A bash trap handler returns to where it was interrupted; it does not exit.
# Without this explicit exit, a TERM from a newer alarm would kill our afplay,
# the poll loop would see the child gone, and it would immediately start
# another one -- the alarm surviving the kill and leaking a player each time.
on_signal() {
  cleanup
  trap - EXIT
  exit 0
}

invoke_alarm() {
  local sound_name="$1" title="$2" body="$3"
  [ "$ENABLED" -eq 1 ] || return 0

  init_state_dir
  stop_running_alarm

  # Written before the trap is armed so a kill during setup still leaves a
  # removable file; the PID guard in stop_running_alarm handles staleness.
  printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null
  chmod 600 "$PID_FILE" 2>/dev/null
  trap cleanup EXIT
  trap on_signal TERM INT

  local bundle sound
  bundle=$(detect_terminal_bundle_id)
  notify "$title" "$body" "$bundle"

  sound=$(resolve_sound "$sound_name") || sound=''
  if [ -z "$sound" ]; then
    # Never fail silently: a mistyped sound name would otherwise turn the whole
    # alarm into a no-op, which is indistinguishable from the hook not firing.
    sound=$(resolve_sound 'Sosumi') || sound=''
    printf 'claude-alarm: sound %s not found, falling back\n' "$sound_name" >&2
  fi

  if [ "$SPEAK" -eq 1 ]; then
    if [ -n "$SPEAK_VOICE" ]; then
      say -v "$SPEAK_VOICE" "$body" >/dev/null 2>&1 &
    else
      say "$body" >/dev/null 2>&1 &
    fi
    SAY_PID=$!
  fi

  if [ "$DIALOG" -eq 1 ] && [ -n "$bundle" ]; then
    CLICK_FILE="$STATE_DIR/click.$$"
    rm -f "$CLICK_FILE" 2>/dev/null
    show_dialog "$title" "$body" "$bundle" "$ALARM_SECONDS" "$CLICK_FILE" &
    DIALOG_PID=$!
  fi

  local deadline poll_s arm_polls polls started raised
  started=$(now_s)
  raised=0
  deadline=$(( $(now_s) + ALARM_SECONDS ))
  poll_s=$(awk "BEGIN{printf \"%.3f\", $POLL_INTERVAL_MS/1000}")
  arm_polls=$(( FOREGROUND_ARM_DELAY_MS / POLL_INTERVAL_MS ))
  polls=0

  while [ "$(now_s)" -lt "$deadline" ]; do
    if [ -n "$sound" ]; then
      afplay "$sound" >/dev/null 2>&1 &
      AF_PID=$!
    else
      AF_PID=''
    fi

    # Poll while the clip plays so dismissal lands within POLL_INTERVAL_MS
    # rather than at the end of a multi-second sound.
    while :; do
      polls=$(( polls + 1 ))

      # You clicked the dialog button: it already raised the terminal.
      if [ -n "$CLICK_FILE" ] && [ -f "$CLICK_FILE" ]; then
        cleanup; trap - EXIT; return 0
      fi

      # The raise and the focus watcher only apply when there is no dialog. With
      # a dialog up they would end the alarm -- and take the dialog down with it
      # -- within seconds: the raise makes the terminal frontmost, which is
      # exactly what the focus watcher treats as "dismissed". The dialog has to
      # outlive that to be clickable, so when it is showing it is the only way
      # the alarm ends early.
      if [ -z "$CLICK_FILE" ]; then
        if [ "$RAISE_TERMINAL_AFTER" -gt 0 ] && [ "$raised" -eq 0 ] && [ -n "$bundle" ] &&
           [ $(( $(now_s) - started )) -ge "$RAISE_TERMINAL_AFTER" ]; then
          open -b "$bundle" >/dev/null 2>&1
          raised=1
        fi

        if [ "$polls" -ge "$arm_polls" ] && [ -n "$bundle" ]; then
          if [ "$(front_bundle_id 2>/dev/null)" = "$bundle" ]; then
            cleanup; trap - EXIT; return 0
          fi
        fi
      fi

      [ "$(now_s)" -ge "$deadline" ] && { cleanup; trap - EXIT; return 0; }

      if [ -n "$AF_PID" ]; then
        kill -0 "$AF_PID" 2>/dev/null || break
      else
        # No usable sound: fall back to the terminal bell instead of silence.
        printf '\a' >&2
      fi

      sleep "$poll_s"
    done
  done

  cleanup
  trap - EXIT
  return 0
}

# --------------------------------------------------------------------------
#  Banner
# --------------------------------------------------------------------------

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Emits a Claude Code hook JSON payload carrying allowlisted terminal escapes.
#   OSC 9 -> desktop notification in iTerm2 / WezTerm / Ghostty (Terminal.app
#            ignores it, which is why the alarm also posts a real notification)
#   OSC 0 -> window+icon title
# ESC and BEL go out as \\u001b / \\u0007: raw control bytes are not legal inside
# a JSON string.
write_banner_json() {
  local title body tag seq
  title=$(json_escape "$1"); body=$(json_escape "$2"); tag=$(json_escape "$3")
  seq="\\u001b]9;$title: $body\\u0007\\u001b]0;$(json_escape "$TITLE_MARKER") $tag - $body\\u0007"
  printf '{"terminalSequence":"%s","suppressOutput":true}\n' "$seq"
}

# --------------------------------------------------------------------------
#  Dispatch
# --------------------------------------------------------------------------

ACTION="$1"
[ -n "$ACTION" ] || { printf 'usage: alarm.sh <action>\n' >&2; exit 0; }

case "$ACTION" in

  start)
    # User typed something: they're awake. Kill any alarm and stamp the turn.
    read_hook_stdin
    init_state_dir
    stop_running_alarm
    remove_stale_turn_files
    KEY=$(get_session_key)
    printf '%s\n' "$(now_s)" > "$(turn_file "$KEY")" 2>/dev/null
    ;;

  stop)
    stop_running_alarm
    ;;

  done)
    read_hook_stdin
    init_state_dir
    KEY=$(get_session_key)
    turn_was_long "$KEY" && invoke_alarm "$SOUND_DONE" "$TITLE_DONE" "$BODY_DONE"
    ;;

  needs-input)
    # No duration gate: if Claude is blocked on you, you want to know now.
    read_hook_stdin
    init_state_dir
    invoke_alarm "$SOUND_NEEDS_INPUT" "$TITLE_NEEDS_INPUT" "$BODY_NEEDS_INPUT"
    ;;

  banner-done)
    read_hook_stdin
    init_state_dir
    KEY=$(get_session_key)
    if [ "$ENABLED" -eq 1 ] && turn_was_long "$KEY"; then
      write_banner_json "$TITLE_DONE" "$BODY_DONE" "$(get_session_tag "$KEY")"
    fi
    ;;

  banner-needs-input)
    read_hook_stdin
    init_state_dir
    KEY=$(get_session_key)
    [ "$ENABLED" -eq 1 ] && \
      write_banner_json "$TITLE_NEEDS_INPUT" "$BODY_NEEDS_INPUT" "$(get_session_tag "$KEY")"
    ;;

  test-done)
    init_state_dir
    invoke_alarm "$SOUND_DONE" "$TITLE_DONE" "$BODY_DONE"
    ;;

  test-needs-input)
    init_state_dir
    invoke_alarm "$SOUND_NEEDS_INPUT" "$TITLE_NEEDS_INPUT" "$BODY_NEEDS_INPUT"
    ;;

  *)
    printf 'claude-alarm: unknown action %s\n' "$ACTION" >&2
    ;;
esac

exit 0
