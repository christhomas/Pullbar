#!/usr/bin/env bash
# Print Markdown release notes for a tag: every pull request merged into main
# since the previous semver tag, with its title, link, author, and description.
#
# Usage: scripts/release-notes.sh <tag>
# Needs git history with tags and an authenticated `gh`. REPO defaults to
# lucaspal/Pullbar; the release workflow sets it to the current repository.
set -euo pipefail

TAG="${1:?usage: scripts/release-notes.sh <tag>}"
REPO="${REPO:-lucaspal/Pullbar}"

PREVIOUS="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$TAG^" 2>/dev/null || true)"
if [ -n "$PREVIOUS" ]; then
    RANGE="$PREVIOUS..$TAG"
else
    RANGE="$TAG"
fi

# A commit can belong to several pull requests, and a pull request has many
# commits, so collect the numbers first and de-duplicate them. On a fork the
# API also returns the parent repository's pull requests, so keep only those
# merged into this repository.
REPO_LOWER="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
PRS="$(
    for sha in $(git rev-list "$RANGE"); do
        gh api "repos/$REPO/commits/$sha/pulls" \
            --jq ".[] | select(.merged_at != null and .base.ref == \"main\" and (.base.repo.full_name | ascii_downcase) == \"$REPO_LOWER\") | .number"
    done | sort -un
)"

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
