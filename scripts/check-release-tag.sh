#!/usr/bin/env bash
# Check that a tag may be released, and print its version.
#
# Usage: scripts/check-release-tag.sh vX.Y.Z [commit] [main-ref]
#
# commit defaults to HEAD and main-ref to origin/main. The tag must be semver,
# its commit must be on main, and that commit must be the release commit for
# the version: the first commit whose CHANGELOG.md has the version's entry.
# That is the "Release vX.Y.Z" commit made by scripts/create-release.sh, or
# the merge of its pull request. So a release always comes from a reviewed
# release pull request; tagging any other main commit, older or newer, fails.
set -euo pipefail

TAG="${1:?usage: scripts/check-release-tag.sh vX.Y.Z [commit] [main-ref]}"
COMMIT="${2:-HEAD}"
MAIN="${3:-origin/main}"
VERSION="${TAG#v}"

fail() { echo "::error::$*" >&2; exit 1; }

# True when CHANGELOG.md at the given commit has an entry for VERSION.
has_entry() {
    git show "$1:CHANGELOG.md" 2>/dev/null |
        awk -v heading="## [$VERSION]" 'index($0, heading) == 1 { found = 1 } END { exit !found }'
}

printf '%s\n' "$TAG" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' ||
    fail "Tag $TAG is not a semver tag like v1.2.3."
git merge-base --is-ancestor "$COMMIT" "$MAIN" ||
    fail "Tag $TAG points to a commit that is not on main. Releases are built only from main."
has_entry "$COMMIT" ||
    fail "Tag $TAG points to a commit whose CHANGELOG.md has no $VERSION entry. Tag the merge of the release pull request from scripts/create-release.sh."
! has_entry "$COMMIT^1" ||
    fail "Tag $TAG points to a commit after the one that added the $VERSION changelog entry. Tag the merge of the release pull request instead."

echo "$VERSION"
