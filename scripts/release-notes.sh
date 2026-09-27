#!/usr/bin/env bash
# Print Markdown notes for every pull request merged into main since the
# previous semver tag.
#
# Usage: scripts/release-notes.sh [--summary] <ref>
#
#   <ref>      A release tag (v1.2.3), or HEAD before tagging.
#   --summary  One line per pull request, for CHANGELOG.md. Without it, the
#              full notes for the GitHub release: title, link, author, merge
#              date, and description of each pull request.
#
# Pull requests from release/* branches (made by scripts/create-release.sh)
# are left out. Needs git history with tags and an authenticated `gh`. REPO
# defaults to lucaspal/Pullbar; the release workflow sets it to the current
# repository.
set -euo pipefail

SUMMARY=false
if [ "${1:-}" = "--summary" ]; then
    SUMMARY=true
    shift
fi
REF="${1:?usage: scripts/release-notes.sh [--summary] <ref>}"
REPO="${REPO:-lucaspal/Pullbar}"

# The previous release is the newest semver tag before REF, not REF itself.
if git tag --points-at "$REF" | grep -q '^v[0-9]'; then
    BEFORE="$REF^"
else
    BEFORE="$REF"
fi
PREVIOUS="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$BEFORE" 2>/dev/null || true)"
if [ -n "$PREVIOUS" ]; then
    RANGE="$PREVIOUS..$REF"
else
    RANGE="$REF"
fi

# A commit can belong to several pull requests, and a pull request has many
# commits, so collect the numbers first and de-duplicate them. On a fork the
# API also returns the parent repository's pull requests, so keep only those
# merged into this repository.
REPO_LOWER="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
COMMITS="$(git rev-list "$RANGE")"
PRS="$(
    for sha in $COMMITS; do
        gh api "repos/$REPO/commits/$sha/pulls" \
            --jq ".[] | select(.merged_at != null and .base.ref == \"main\" and (.base.repo.full_name | ascii_downcase) == \"$REPO_LOWER\" and (.head.ref | startswith(\"release/\") | not)) | .number"
    done | sort -un
)"

if $SUMMARY; then
    for number in $PRS; do
        gh pr view "$number" --repo "$REPO" --json number,title,url,author \
            --template '- {{.title}} ([#{{.number}}]({{.url}})) by @{{.author.login}}
'
    done
    exit 0
fi

if [ -n "$PREVIOUS" ]; then
    echo "Changes since [$PREVIOUS](https://github.com/$REPO/releases/tag/$PREVIOUS)."
else
    echo "First release."
fi
echo

if [ -z "$PRS" ]; then
    echo "No pull requests were merged in this release."
    exit 0
fi

for number in $PRS; do
    entry="$(gh pr view "$number" --repo "$REPO" \
        --json number,title,url,author,mergedAt,body \
        --template '## [{{.title}}]({{.url}}) (#{{.number}})

By @{{.author.login}}, merged {{timefmt "2006-01-02" .mergedAt}}.

{{.body}}
')"
    # Demote the description's own headings below the pull request heading,
    # leaving fenced code blocks alone.
    printf '%s\n' "$entry" |
        awk '/^```/ { fence = !fence } !fence && /^#+ / && NR > 1 { $0 = "#" $0 } { print }'
    echo
done
