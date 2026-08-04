#!/bin/bash
#
# Give claude-notify's banners a custom icon.  macOS only.
#
#   ./install-notifier-icon.sh path/to/image.png
#
# The icon shown in a notification belongs to the app that posted it, so this
# writes into claude-notify's bundle rather than anything of ours. That also
# means a reinstall or update of claude-notify wipes it -- which is the reason
# this is a script instead of a one-off set of commands. Re-run it afterwards.
#
# Any format sips can read works (png, jpg, heic, tiff). Non-square input is
# padded rather than cropped, so nothing is cut off.

set -e

SRC="$1"
APP="${CLAUDE_NOTIFY_APP:-/Applications/ClaudeNotify.app}"

[ -n "$SRC" ] || { echo "usage: $(basename "$0") <image>" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }
[ -d "$APP" ] || {
  echo "claude-notify not found at $APP" >&2
  echo "install it first: https://github.com/armandsalle/claude-notify" >&2
  exit 1
}

W=$(sips -g pixelWidth  "$SRC" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/{print $2}')
[ -n "$W" ] || { echo "cannot read image: $SRC" >&2; exit 1; }
echo "source ${W}x${H}"

# 1024 is the largest size an icns holds. Upscaling past the source is lossy but
# harmless -- macOS picks the size it needs, and the small ones are what a
# notification actually shows.
[ "$W" -lt 1024 ] && echo "note: smaller than 1024px, large sizes will be soft"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SQ="$TMP/square.png"

# Pad to square on the longest edge so nothing is cropped out of frame.
MAX=$W; [ "$H" -gt "$MAX" ] && MAX=$H
sips -s format png "$SRC" --out "$TMP/src.png" >/dev/null
sips -p "$MAX" "$MAX" --padColor FFFFFF "$TMP/src.png" --out "$SQ" >/dev/null

SET="$TMP/icon.iconset"
mkdir -p "$SET"
# The @2x names are required: iconutil rejects an iconset missing them.
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  px=${spec%% *}; name=${spec##* }
  sips -z "$px" "$px" "$SQ" --out "$SET/icon_$name.png" >/dev/null
done

iconutil -c icns "$SET" -o "$TMP/ClaudeNotify.icns"

mkdir -p "$APP/Contents/Resources"
cp "$TMP/ClaudeNotify.icns" "$APP/Contents/Resources/ClaudeNotify.icns"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string ClaudeNotify' "$APP/Contents/Info.plist"

# Editing the bundle invalidates the signature; without re-signing the app is
# refused notification authorization entirely.
codesign --force --deep --sign - "$APP"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP"

# The daemon caches its icon at launch, so a running one keeps showing the old.
if pgrep -f ClaudeNotify >/dev/null 2>&1; then
  pkill -f ClaudeNotify || true
  sleep 1
fi

echo "installed. testing:"
"$APP/Contents/MacOS/ClaudeNotify" -m "Icon installed." -t "Claude Code" -a com.apple.Terminal >/dev/null 2>&1 &
sleep 3
echo "done -- if the banner still shows the old icon, log out and back in (macOS caches icons aggressively)."
