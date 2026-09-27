# Agent notes for pullbar

pullbar is a macOS menu bar app (Swift, AppKit, no dependencies). See `README.md`
for features and `Makefile` for build targets (`make run`, `make app`, `make install`).

## Taking a screenshot of the menu

The app does not block screen capture. Past failures came from the environment,
so follow these steps instead of assuming an app bug.

### Prerequisites

The host app that runs your shell (terminal, IDE, agent host) needs both
permissions in System Settings > Privacy & Security:

- **Screen Recording**: without it, `screencapture` fails with
  `could not create image from display`.
- **Accessibility**: without it, `osascript` fails with
  `osascript is not allowed assistive access`.

The host app may need a restart after the user grants a permission. If
either permission is missing, ask the user to grant it. Do not work around it.

### Multiple displays

The user may have several displays. The status item and its menu can be on
any of them, often not on the main display. Plain `screencapture file.png`
captures **only the main display**, so the menu will be missing from the image.

Always pass one file name per display (this example is for three displays):

```sh
screencapture -x /tmp/d1.png /tmp/d2.png /tmp/d3.png
```

To see where the status item is, check its global position (points; negative
values mean a display left of or above the main display):

```sh
osascript -e 'tell application "System Events" to tell process "pullbar" to get {position, size} of menu bar item 1 of menu bar 1'
```

List displays with `system_profiler SPDisplaysDataType`.

### Opening the menu and capturing it

The status item lives in `menu bar 1` of process `pullbar` (not `menu bar 2`).
Start a delayed capture in a background job, click the status item to open
the menu, then press Escape to close it:

```sh
(sleep 3
 osascript -e 'tell application "System Events" to tell process "pullbar" to get {position, size} of menu 1 of menu bar item 1 of menu bar 1'
 screencapture -x /tmp/d1.png /tmp/d2.png /tmp/d3.png
 sleep 1
 osascript -e 'tell application "System Events" to key code 53') &
osascript -e 'tell application "System Events" to tell process "pullbar" to click menu bar item 1 of menu bar 1' >/dev/null
wait
```

The first `osascript` line in the background job prints the menu's position and
size, which confirms that the menu was open at capture time. Then find the
display image that contains the menu and crop it with `sips`, for example:

```sh
sips -c <height> <width> --cropOffset <y> <x> /tmp/d3.png --out /tmp/pullbar-menu.png
```

Offsets and sizes are in pixels. Retina displays use 2 pixels per point,
so double the values `osascript` reports.

### Things that close the menu

- Cmd+Shift+5 (the Screenshot app) takes focus, and any open menu closes.
  For a manual capture, use Cmd+Shift+4, press Space, then click the menu.
  Or use `screencapture -T 5 ...` and open the menu during the 5-second delay.
- Screenshots can contain private content from other apps on the same
  display. Crop to the menu before you save or share an image.
