#!/bin/sh
# Record where a build came from in the app bundle's Info.plist, so the app can
# show it (the title row at the top of the menu).
#
# Usage: Packaging/stamp-build-info.sh <path/to/Info.plist>
#
#   PullbarBuildDescription  `git describe --tags --always --dirty`: the tag
#                            for a release build, or tag-commits-gHASH, with
#                            -dirty for uncommitted changes.
#   PullbarSourceRepository  https URL of the repository the build came from:
#                            $GITHUB_REPOSITORY in GitHub Actions, otherwise
#                            the `origin` remote.
#
# Either key is left out when git cannot tell, e.g. outside a git checkout.
set -eu

PLIST="${1:?usage: Packaging/stamp-build-info.sh <Info.plist>}"

set_key() {
    /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" 2>/dev/null || true
    [ -n "$2" ] && /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
    return 0
}

describe="$(git describe --tags --always --dirty 2>/dev/null || true)"

if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    repository="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"
else
    # git@github.com:owner/repo.git or https://github.com/owner/repo(.git)
    repository="$(git remote get-url origin 2>/dev/null \
        | sed -E 's#^git@([^:]+):#https://\1/#; s#\.git$##' || true)"
fi

set_key PullbarBuildDescription "$describe"
set_key PullbarSourceRepository "$repository"
