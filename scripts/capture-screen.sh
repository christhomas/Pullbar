#!/usr/bin/env bash
# Take a screenshot of the open pullbar menu.
#
# Usage: scripts/capture-screen.sh [--with-status-item] [--delay SECONDS] [output.png]
#
#   output.png          Where to write the image (default: /tmp/pullbar-menu.png).
#   --with-status-item  Also include the menu bar icon above the menu.
#   --delay SECONDS     Wait this long after the menu opens (default: 1), so it
#                       finishes drawing. With 0 the image can catch the
#                       fade-in and look translucent.
#
# The script opens the menu, waits for it, captures exactly its rectangle on
# whichever display it is on, and closes it again. pullbar must be running,
# and the app that runs this script needs the Screen Recording and
# Accessibility permissions (System Settings > Privacy & Security).
set -euo pipefail

OUTPUT=/tmp/pullbar-menu.png
DELAY=1
WITH_ITEM=false
while [ $# -gt 0 ]; do
    case "$1" in
        --with-status-item) WITH_ITEM=true ;;
        --delay) DELAY="${2:?--delay needs a number of seconds}"; shift ;;
        -h|--help) sed -n '2,17s/^# \{0,1\}//p' "$0"; exit 0 ;;
        -*) echo "error: unknown option $1" >&2; exit 1 ;;
        *) OUTPUT="$1" ;;
    esac
    shift
done

fail() { echo "error: $*" >&2; exit 1; }

ITEM='menu bar item 1 of menu bar 1'
MENU="menu 1 of $ITEM"

# Run AppleScript against the pullbar process; turn permission errors into a
# clear message.
ax() {
    local out
    if ! out="$(osascript -e "tell application \"System Events\" to tell process \"pullbar\" to $1" 2>&1)"; then
        case "$out" in
            *"assistive access"*|*"not allowed to send keystrokes"*|*"-25211"*)
                fail "Accessibility permission is missing. Grant it to the app running this script in System Settings > Privacy & Security > Accessibility, then restart that app." ;;
            *) fail "AppleScript failed: $out" ;;
        esac
    fi
    printf '%s\n' "$out"
}

# "x, y, w, h" (points, global coordinates) -> "x,y,w,h"
rect_of() { ax "get {position, size} of $1" | tr -d ' '; }

pgrep -x pullbar >/dev/null ||
    fail "pullbar is not running. Start it with 'make run' or 'make install'."

# The menu element always exists; while the menu is closed its size is 0x0.
menu_open() {
    local w
    w="$(rect_of "$MENU" 2>/dev/null | cut -d, -f3)" || return 1
    [ "${w:-0}" -gt 0 ]
}

# AXCancel closes the menu reliably; Escape is ignored right after it opens.
close_menu() {
    if menu_open; then
        (ax "perform action \"AXCancel\" of $MENU") >/dev/null 2>&1 || true
    fi
}

# Check Accessibility once here, where a failure stops the script; later
# checks run in subshells.
ax "exists $ITEM" >/dev/null
close_menu
ITEM_RECT="$(rect_of "$ITEM")"
trap close_menu EXIT

# The click returns once the menu is open (about 2 seconds). If it did not
# open, poll briefly and click once more.
open_menu() {
    ax "click $ITEM" >/dev/null
    for _ in $(seq 20); do
        menu_open && return 0
        sleep 0.1
    done
    return 1
}
open_menu || open_menu || fail "the menu did not open."
sleep "$DELAY"
RECT="$(rect_of "$MENU")"

if $WITH_ITEM; then
    IFS=, read -r ix iy iw ih <<< "$ITEM_RECT"
    IFS=, read -r mx my mw mh <<< "$RECT"
    x=$(( ix < mx ? ix : mx )); y=$(( iy < my ? iy : my ))
    right=$(( ix + iw > mx + mw ? ix + iw : mx + mw ))
    bottom=$(( iy + ih > my + mh ? iy + ih : my + mh ))
    RECT="$x,$y,$(( right - x )),$(( bottom - y ))"
fi

rm -f "$OUTPUT"
ERR="$(screencapture -x -R"$RECT" "$OUTPUT" 2>&1)" || true
if [ ! -s "$OUTPUT" ]; then
    case "$ERR" in
        *"could not create image"*)
            fail "Screen Recording permission is missing. Grant it to the app running this script in System Settings > Privacy & Security > Screen Recording, then restart that app." ;;
        *) fail "screencapture failed: ${ERR:-no image written}" ;;
    esac
fi

echo "$OUTPUT"
