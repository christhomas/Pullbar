#!/usr/bin/env bash
# Take a screenshot of the open pullbar menu.
#
# Usage: scripts/capture-screen.sh [--fixture NAME|FILE] [--with-status-item] [--delay SECONDS] [output.png]
#
#   output.png          Where to write the image (default: /tmp/pullbar-menu.png).
#   --fixture NAME      Show a made-up inbox instead of your own: Fixtures/NAME.json
#                       (e.g. showcase, empty, error) or a path to a fixture file.
#                       pullbar is relaunched with it for the capture, then
#                       relaunched as it was. Screenshots made this way show no
#                       real pull requests, so they are safe to publish.
#   --with-status-item  Also include the menu bar icon above the menu.
#   --delay SECONDS     Wait this long after the menu opens (default: 1), so it
#                       finishes drawing. With 0 the image can catch the
#                       fade-in and look translucent.
#
# The script opens the menu, waits for it, captures exactly its rectangle on
# whichever display it is on, and closes it again. It retries when the menu
# closes or moves during the capture (for example after a click elsewhere).
# pullbar must be running, or built as build/pullbar.app when --fixture is
# used, and the app that runs this script needs the Screen Recording and
# Accessibility permissions (System Settings > Privacy & Security).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT=/tmp/pullbar-menu.png
DELAY=1
WITH_ITEM=false
FIXTURE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fixture) FIXTURE="${2:?--fixture needs a fixture name or file}"; shift ;;
        --with-status-item) WITH_ITEM=true ;;
        --delay) DELAY="${2:?--delay needs a number of seconds}"; shift ;;
        -h|--help) sed -n '2,22s/^# \{0,1\}//p' "$0"; exit 0 ;;
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

quit_pullbar() {
    osascript -e 'quit app "pullbar"' >/dev/null 2>&1 || true
    for _ in $(seq 50); do
        pgrep -x pullbar >/dev/null || return 0
        sleep 0.1
    done
    fail "pullbar did not quit."
}

# Launch pullbar and wait until its menu bar item answers.
launch_pullbar() {
    open "$@"
    for _ in $(seq 100); do
        (ax "exists $ITEM") 2>/dev/null | grep -qx true && { sleep 1; return 0; }
        sleep 0.1
    done
    fail "pullbar did not start."
}

# --fixture: remember how pullbar was running, relaunch it with the fixture,
# and put it back afterwards.
APP=""
WAS_RUNNING=false
restore_app() {
    [ -n "$FIXTURE" ] || return 0
    quit_pullbar
    if $WAS_RUNNING; then open "$APP"; fi
}
cleanup() {
    close_menu
    restore_app
}

if [ -n "$FIXTURE" ]; then
    case "$FIXTURE" in
        */*|*.json) file="$FIXTURE" ;;
        *) file="$ROOT/Fixtures/$FIXTURE.json" ;;
    esac
    [ -f "$file" ] || fail "no fixture at $file (see Fixtures/)."
    file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"

    if pid="$(pgrep -x pullbar | head -n 1)"; then
        WAS_RUNNING=true
        exe="$(ps -o comm= -p "$pid")"
        APP="${exe%/Contents/MacOS/*}"
    else
        APP="$ROOT/build/pullbar.app"
    fi
    case "$APP" in
        *.app) [ -d "$APP" ] || fail "no app at $APP. Run 'make app' first." ;;
        *) fail "pullbar is running outside an app bundle ($APP); --fixture needs one. Run 'make app' first." ;;
    esac

    quit_pullbar
    trap cleanup EXIT
    launch_pullbar "$APP" --args --fixture "$file"
else
    pgrep -x pullbar >/dev/null ||
        fail "pullbar is not running. Start it with 'make run' or 'make install'."
    trap cleanup EXIT
fi

# Check Accessibility here, where a failure stops the script; later checks run
# in subshells.
ax "exists $ITEM" >/dev/null

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

# One attempt: open the menu, capture its rectangle, and check that it was
# still open, at the same place, afterwards. Returns 1 to retry.
capture_once() {
    local menu_rect rect ix iy iw ih mx my mw mh x y right bottom err
    close_menu
    open_menu || open_menu || return 1
    sleep "$DELAY"

    menu_rect="$(rect_of "$MENU")"
    IFS=, read -r mx my mw mh <<< "$menu_rect"
    [ "${mw:-0}" -gt 0 ] && [ "${mh:-0}" -gt 0 ] || return 1
    rect="$menu_rect"

    if $WITH_ITEM; then
        IFS=, read -r ix iy iw ih <<< "$(rect_of "$ITEM")"
        x=$(( ix < mx ? ix : mx )); y=$(( iy < my ? iy : my ))
        right=$(( ix + iw > mx + mw ? ix + iw : mx + mw ))
        bottom=$(( iy + ih > my + mh ? iy + ih : my + mh ))
        rect="$x,$y,$(( right - x )),$(( bottom - y ))"
    fi

    rm -f "$OUTPUT"
    err="$(screencapture -x -R"$rect" "$OUTPUT" 2>&1)" || true
    if [ ! -s "$OUTPUT" ]; then
        case "$err" in
            *"could not create image"*)
                fail "Screen Recording permission is missing. Grant it to the app running this script in System Settings > Privacy & Security > Screen Recording, then restart that app." ;;
            *) fail "screencapture failed: ${err:-no image written}" ;;
        esac
    fi

    [ "$(rect_of "$MENU")" = "$menu_rect" ] || return 1
}

for attempt in 1 2 3; do
    capture_once && break
    rm -f "$OUTPUT"
    [ "$attempt" -lt 3 ] ||
        fail "the menu closed or moved during every attempt. Avoid clicking or typing while it captures."
    sleep 1
done

echo "$OUTPUT"
