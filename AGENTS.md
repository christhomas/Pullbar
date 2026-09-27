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

## Making a release

Releases are built only from `main` and are started by pushing a semver tag
(`v1.2.3`, or `v1.2.3-rc.1` for a pre-release). The tag push runs the
**Build** workflow (`.github/workflows/build.yml`), which checks the tag,
builds and signs the app with that version, writes the release notes from the
merged pull requests (`scripts/release-notes.sh`), and publishes a GitHub
release with the zipped app.

The changelog is prepared locally first, so the tagged commit already
contains its own `CHANGELOG.md` entry and README section. Do not edit the
README changelog block (between `<!-- changelog:start -->` and
`<!-- changelog:end -->`) by hand; `scripts/changelog.py` owns it.

### Steps

1. Pick the version. Follow semver from the changes since the last tag:
   breaking change = major, new feature = minor, fixes only = patch. Check the
   last tag with `git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main`.
   Ask the user if the version is not obvious.
2. Optional: add highlights under `## Unreleased` in `CHANGELOG.md`, run
   `scripts/changelog.py readme`, and merge that to `main` first. The merged
   pull requests are listed automatically, so this is only for a summary.
3. Start from an up-to-date `main` with a clean working tree, then prepare
   the release:

   ```sh
   git switch main && git pull origin main
   scripts/create-release.sh v1.2.3
   ```

   The script checks the tag, creates the `release/v1.2.3` branch, moves the
   Unreleased notes into a `1.2.3` entry, adds the list of pull requests
   merged since the previous tag, refreshes the README block, and commits
   `Release v1.2.3`. Review the commit (`git show`) before you continue.
4. Push the branch and open a pull request:

   ```sh
   git push -u origin release/v1.2.3
   gh pr create --base main --head release/v1.2.3 --title "Release v1.2.3" --fill
   ```

5. After the pull request is merged, tag the merge commit on `main`:

   ```sh
   git switch main && git pull origin main
   git tag -a v1.2.3 -m "Release v1.2.3"
   git push origin v1.2.3
   ```

6. Watch the run with `gh run watch`, then check the release with
   `gh release view v1.2.3`: it must have the `pullbar-1.2.3.zip` asset and
   notes for each merged pull request.

Pushing a tag publishes a release, so only do steps 4 and 5 when the user has
asked for the release.

### Notes

- The scripts look up pull requests in `lucaspal/Pullbar`. On a fork, set
  `REPO=<owner>/Pullbar` (and `REMOTE=<remote>` if `main` is not on `origin`)
  for `create-release.sh`; the workflow uses the repository it runs in.
- Pull requests from `release/*` branches are left out of the notes and the
  changelog list.
- If the workflow fails at "Check release tag", the tag is not semver or its
  commit is not on `main`. Delete the tag (`git push origin :refs/tags/v1.2.3`
  and `git tag -d v1.2.3`), fix the cause, and tag again.
- The app is ad-hoc signed, not notarized, so macOS warns people who
  download it from the release.
