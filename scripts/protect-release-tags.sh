#!/usr/bin/env bash
# Let only repository admins create, move, or delete release tags.
#
# Usage: scripts/protect-release-tags.sh [--repo owner/name]
#
# Pushing a v* tag makes the Build workflow publish a release, and the rules
# that protect main do not cover tags. This creates (or updates) a tag
# ruleset named "Release tags" that blocks creating, updating, and deleting
# refs/tags/v* for everyone except the repository admin role. Running it
# again is safe.
#
# Needs an authenticated `gh` with admin rights on the repository.
set -euo pipefail

REPO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs owner/name}"; shift ;;
        -h|--help) sed -n '2,12s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *) echo "error: unknown argument $1" >&2; exit 1 ;;
    esac
    shift
done
[ -n "$REPO" ] || REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

NAME="Release tags"

# actor_id 5 is GitHub's built-in repository admin role.
ruleset() {
    cat <<EOF
{
  "name": "$NAME",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}],
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
}
EOF
}

id="$(gh api "repos/$REPO/rulesets?targets=tag" --jq ".[] | select(.name == \"$NAME\") | .id")"
if [ -n "$id" ]; then
    ruleset | gh api -X PUT "repos/$REPO/rulesets/$id" --silent --input -
    echo "Updated the '$NAME' ruleset on $REPO."
else
    ruleset | gh api -X POST "repos/$REPO/rulesets" --silent --input -
    echo "Created the '$NAME' ruleset on $REPO."
fi
echo "Only repository admins can now create, move, or delete v* tags."
