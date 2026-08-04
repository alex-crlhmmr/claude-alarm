#!/bin/bash
#
# Builds FocusClaudeTab.app, which makes clicking a banner land on the exact
# terminal tab Claude is running in rather than just bringing the terminal app
# forward.  macOS + Terminal.app only.
#
# Why an app and not a script: claude-notify can only *activate an app* when a
# notification is clicked, it cannot run a command. So the click points at this
# app, whose whole job is to select the right tab and quit. alarm.sh writes the
# target tty to ~/.claude/hooks/.alarm-state/focus-tty before posting.
#
# Why tty and not the window title: Claude Code overwrites the terminal title
# with its own session name, so the OSC 0 marker the banner hook writes is not
# reliably there to match on. A tty is exact and cannot collide, and Terminal
# exposes it per tab.
#
# Requires Automation permission for Terminal, requested once on first click.

set -e

APP="$HOME/Applications/FocusClaudeTab.app"
BUNDLE_ID='com.claudealarm.focustab'
SRC="$(cd "$(dirname "$0")" && pwd)/focus.applescript"

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

mkdir -p "$HOME/Applications"
rm -rf "$APP"
# -s: stay open. A plain activate -- which is all claude-notify does on click --
# will not re-run a just-exited applet, so a quit-after-run build only focused
# the tab about one click in three. Staying open means the click reopens a live
# process instead, and the script handles both run and reopen.
osacompile -s -o "$APP" "$SRC"

# osacompile stamps its own generic identifier; alarm.sh needs a stable one to
# hand to claude-notify's -a flag.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$APP/Contents/Info.plist"
# No dock icon: it exists for a fraction of a second per click.
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$APP/Contents/Info.plist" 2>/dev/null || true

codesign --force --deep -s - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP"

echo "installed $APP  ($BUNDLE_ID)"
echo
echo "alarm.sh picks it up automatically. The first click will ask for permission"
echo "to control Terminal -- approve it, or the click can only raise the app."
