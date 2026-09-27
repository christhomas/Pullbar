#!/usr/bin/env bash
# Check that the unit tests catch real bugs.
#
# Usage: scripts/mutation-test.sh
#
# Each mutation below is one small, deliberate bug in the app's code: a
# flipped condition, a wrong label, a dropped filter. For each, the script
# applies it, runs `swift test`, and restores the file. A mutation the tests
# do not notice ("survived") means a missing or weak test. The script exits
# non-zero if any mutation survives, or if one no longer applies because the
# code changed (then update its pattern here).
#
# Run it on a clean working tree; it refuses otherwise, since it restores
# files with `git checkout`.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ -n "$(git status --porcelain -- Sources)" ]; then
    echo "error: Sources/ has uncommitted changes; commit or stash them first." >&2
    exit 1
fi

# file @@ perl substitution (applied once) @@ what the bug is
MUTATIONS=(
    "Sources/pullbar/Models.swift@@s/state == \.failure \|\| state == \.error/state == .failure/@@an ERROR check no longer counts as failing"
    "Sources/pullbar/Models.swift@@s/state == \.pending \|\| state == \.expected/state == .pending/@@an EXPECTED check no longer counts as pending"
    "Sources/pullbar/Models.swift@@s/ \|\| mergeable == \.conflicting\n/\n/@@a merge conflict no longer needs action"
    "Sources/pullbar/Models.swift@@s/ \|\| reviewDecision == nil//@@no review required no longer counts as ready"
    "Sources/pullbar/Models.swift@@s/checks == nil \|\| //@@no checks no longer counts as ready"
    "Sources/pullbar/Models.swift@@s/if isDraft \{ return \"Not ready\" \}//@@drafts show their review state"
    "Sources/pullbar/Models.swift@@s/case \.reviewRequired: return \"Awaiting approval\"/case .reviewRequired: return \"Approved\"/@@wrong review label"
    "Sources/pullbar/Models.swift@@s/filter \{ !direct\.contains/filter { direct.contains/@@team requests become direct requests"
    "Sources/pullbar/Models.swift@@s/\\\$0\.updatedAt > \\\$1\.updatedAt/\\\$0.updatedAt < \\\$1.updatedAt/@@sections sorted oldest first"
    "Sources/pullbar/Models.swift@@s/if pr\.isDraft \{/if false {/@@drafts are not recognised"
    "Sources/pullbar/Models.swift@@s/case \.waitingForReviewOrChecks: return \"All caught up\"/case .waitingForReviewOrChecks: return \"\"/@@empty section text lost"
    "Sources/pullbar/Settings.swift@@s/case \.week: return 7/case .week: return 8/@@wrong window length"
    "Sources/pullbar/Settings.swift@@s/value: -days/value: days/@@updated filter looks into the future"
    "Sources/pullbar/Settings.swift@@s/return v > 0 \? v : 120/return v > 0 ? v : 60/@@wrong default refresh interval"
    "Sources/pullbar/Settings.swift@@s/\?\? \.month/?? .week/@@wrong default updated window"
    "Sources/pullbar/GitHubClient.swift@@s/\[\"SUCCESS\", \"NEUTRAL\", \"SKIPPED\"\]/[\"SUCCESS\", \"NEUTRAL\"]/@@skipped checks no longer pass"
    "Sources/pullbar/GitHubClient.swift@@s/filter \{ \\\$0\.state == \"SUCCESS\" \}/filter { \\\$0.state != \"FAILURE\" }/@@pending statuses count as passed"
    "Sources/pullbar/GitHubClient.swift@@s/reduce\(0\) \{ \\\$0 \+ \\\$1\.count \}/reduce(0) { \\\$0 + min(\\\$1.count, 100) }/@@more than 100 checks undercounted"
    "Sources/pullbar/GitHubClient.swift@@s/contexts\(first: 0\)/contexts(first: 100)/@@query fetches the check list again"
    "Sources/pullbar/GitHubClient.swift@@s/statusCode == 401/statusCode == 403/@@401 not reported as a bad token"
    "Sources/pullbar/GitHubClient.swift@@s/!errors\.isEmpty, envelope\.data == nil/!errors.isEmpty/@@partial data thrown away"
    "Sources/pullbar/GitHubClient.swift@@s/\?\? \"ghost\"/?? \"\"/@@missing author not shown as ghost"
    "Sources/pullbar/GitHubClient.swift@@s/\"is:pr \\\\\(query\)\"/\"\\\\(query)\"/@@searches include issues"
    "Sources/pullbar/GitHubClient.swift@@s/\"first\": 100/\"first\": 50/@@wrong page size"
    "Sources/pullbar/GitHubClient.swift@@s/\"Bearer \\\\\(token\)\"/\"token \\\\(token)\"/@@wrong authorization header"
    "Sources/pullbar/InboxService.swift@@s/user-review-requested:\@me/review-requested:\@me/@@direct review requests not searched"
    "Sources/pullbar/InboxService.swift@@s/\"archived:false\", //@@archived repositories included"
    "Sources/pullbar/Keychain.swift@@s/return token\.isEmpty \? nil : token/return token/@@empty token treated as a token"
    "Sources/pullbar/Keychain.swift@@s/deleteToken\(service: service\)\n        var attrs/var attrs/@@writing over an existing token fails"
    "Sources/pullbar/TokenProvider.swift@@s/== \.command \&\&/!= [] \&\&/@@any modifier pastes"
    "Sources/pullbar/TokenProvider.swift@@s/intersection\(\[\.command, \.shift, \.option, \.control\]\)/intersection(.deviceIndependentFlagsMask)/@@Caps Lock stops Cmd-V from pasting"
    "Sources/pullbar/TokenProvider.swift@@s/guard process\.terminationStatus == 0 else \{ return nil \}//@@a failing gh command still gives a token"
    "Sources/pullbar/AppDelegate.swift@@s/title \+= \"\+\\\\\(teams\)\"/title += \"-\\\\(teams)\"/@@team count shown wrongly"
    "Sources/pullbar/AppDelegate.swift@@s/if error != nil \{ title = /if false { title = /@@failed refresh not flagged"
    "Sources/pullbar/AppDelegate.swift@@s/String\(s\.prefix\(max - 1\)\)/String(s.prefix(max))/@@truncated titles too long"
    "Sources/pullbar/AppDelegate.swift@@s/seconds < 120 \?/seconds <= 120 ?/@@wrong interval label"
    "Sources/pullbar/AppDelegate.swift@@s/inbox == nil \? \"Loading…\" : section\.emptyText/section.emptyText/@@no loading state"
    "Sources/pullbar/AppDelegate.swift@@s/item\.representedObject = pr\.url/item.representedObject = nil/@@clicking a pull request opens nothing"
    "Sources/pullbar/Models.swift@@s/newestA != newestB \? newestA > newestB : //@@groups ordered by name, not time"
    "Sources/pullbar/Models.swift@@s/pullRequests: \\\$0\.value\.sorted\(by: newestFirst\)/pullRequests: \\\$0.value/@@groups not newest first inside"
    "Sources/pullbar/Models.swift@@s/== \.orderedAscending/== .orderedDescending/@@tied owners in reverse order"
    "Sources/pullbar/AppDelegate.swift@@s/                menu\.addItem\(ownerHeader\(group\.owner\)\)\n//@@no owner subheadings"
    "Sources/pullbar/AppDelegate.swift@@s/label\.textColor = \.labelColor/label.textColor = .secondaryLabelColor/@@owner subheadings grey again"
    "Sources/pullbar/AppDelegate.swift@@s/\[\.font: NSFont\.boldSystemFont\(ofSize: 11\), \.foregroundColor: NSColor\.secondaryLabelColor\]/[.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]/@@owner not bold in rows"
    "Sources/pullbar/Models.swift@@s/remaining \* 10 < limit/remaining * 5 < limit/@@low-budget threshold wrong"
    "Sources/pullbar/InboxService.swift@@s/\.min\(by: \{ \\\$0\.remaining < \\\$1\.remaining \}\)/.max(by: { \\\$0.remaining < \\\$1.remaining })/@@refresh reports the highest budget, not the lowest"
    "Sources/pullbar/GitHubClient.swift@@s/                cost \+= limit\.cost\n//@@refresh cost not counted"
    "Sources/pullbar/GitHubClient.swift@@s/            requests \+= 1\n//@@requests not counted"
    "Sources/pullbar/GitHubClient.swift@@s/\"x-ratelimit-remaining\"\) == \"0\"/\"x-ratelimit-remaining\") == \"1\"/@@HTTP rate limit not recognised"
    "Sources/pullbar/GitHubClient.swift@@s/\\\$0\.type == \"RATE_LIMITED\"/\\\$0.type == \"RATE_LIMIT\"/@@GraphQL rate limit not recognised"
    "Sources/pullbar/AppDelegate.swift@@s/usage\.isLow \? \.systemOrange : \.secondaryLabelColor/usage.isLow ? .secondaryLabelColor : .secondaryLabelColor/@@low budget not orange"
    "Sources/pullbar/AppDelegate.swift@@s/let when = age < 1 \?/let when = age < 0 ?/@@just fetched reads in 0 seconds"
    "Sources/pullbar/AppDelegate.swift@@s/if let usage = inbox\.apiUsage, usage\.isLow \{/if let usage = inbox.apiUsage, usage.isLow, false {/@@low budget missing from the menu bar tooltip"
    "Sources/pullbar/MenuColumns.swift@@s/filter \{ \\\$0 == 0 \|\| widths\[\\\$0\] > 0 \}/filter { _ in true }/@@empty status columns still take space"
    "Sources/pullbar/MenuColumns.swift@@s/max\(\(widths\.first \?\? 0\) \+ statusWidth, widestTitle\)/(widths.first ?? 0) + statusWidth/@@status block ignores wide titles"
    "Sources/pullbar/MenuColumns.swift@@s/            x \+= Self\.gap\n//@@no gap between columns"
    "Sources/pullbar/AppDelegate.swift@@s/\? NSAttributedString\(string: \"⚠︎ conflicts\"/? NSAttributedString(string: \"conflicts\"/@@conflict column loses its icon"
    "Sources/pullbar/Fixture.swift@@s/\"h\": 3600/\"h\": 60/@@fixture hours read as minutes"
    "Sources/pullbar/Fixture.swift@@s/mergeable \?\? \"MERGEABLE\"/mergeable ?? \"UNKNOWN\"/@@fixture pull requests default to unknown mergeability"
    "Sources/pullbar/Fixture.swift@@s/userReviewRequested: direct,/userReviewRequested: [],/@@fixture direct requests shown as team requests"
    "Sources/pullbar/Fixture.swift@@s/index \+ 1 < arguments\.count/index < arguments.count/@@--fixture without a value crashes"
    "Sources/pullbar/AppDelegate.swift@@s/lastError = fixture\.error\.map/lastError = nil; _ = fixture.error.map/@@fixture error message not shown"
    "Sources/pullbar/LaunchAtLogin.swift@@s/bundlePath\.contains\(\"\/AppTranslocation\/\"\)/bundlePath.contains(\"\/Translocation\/\")/@@quarantined downloads not detected"
    "Sources/pullbar/LaunchAtLogin.swift@@s/case \.requiresApproval: return \.needsApproval/case .requiresApproval: return .available(enabled: false)/@@switched-off login item looks like off"
    "Sources/pullbar/LaunchAtLogin.swift@@s/bundlePath\.contains\(\"\/Cellar\/\"\)/false/@@Homebrew formula installs not detected"
    "Sources/pullbar/AppDelegate.swift@@s/return \"PullBar version .\\(version\\)\"/return \"PullBar \\\\(version)\"/@@title row wording changed"
    "Sources/pullbar/AppDelegate.swift@@s/\.joined\(separator: \" · \"\)\n\n        let item = NSMenuItem\(title: title/.joined(separator: \" \")\n\n        let item = NSMenuItem(title: title/@@build details run together"
    "Sources/pullbar/AppDelegate.swift@@s/            item\.isEnabled = false\n        \}\n        return item\n    \}\n\n    \@objc private func openBuildRepository/        }\n        return item\n    }\n\n    \@objc private func openBuildRepository/@@title row without a repository is clickable"
    "Sources/pullbar/AppDelegate.swift@@s/        if menuIsOpen \{\n            rebuildMenu\(\)\n/        if menuIsOpen {\n/@@open menu not updated by a refresh"
    "Sources/pullbar/AppDelegate.swift@@s/            statusTitleIsStale = true\n            return\n/            return\n/@@menu bar title never updated after the menu closes"
    "Sources/pullbar/AppDelegate.swift@@s/RunLoop\.main\.add\(timer, forMode: \.common\)/RunLoop.main.add(timer, forMode: .default)/@@refresh timer pauses while the menu is open"
)

echo "Baseline: the tests must pass before mutating."
if ! swift test >/tmp/mutation-baseline.log 2>&1; then
    echo "error: tests fail without any mutation; see /tmp/mutation-baseline.log" >&2
    exit 1
fi

killed=0
survived=()
stale=()
for entry in "${MUTATIONS[@]}"; do
    file="${entry%%@@*}"
    rest="${entry#*@@}"
    expr="${rest%@@*}"
    label="${rest##*@@}"
    before="$(shasum "$file")"
    perl -0pi -e "$expr" "$file"
    if [ "$(shasum "$file")" = "$before" ]; then
        stale+=("$label ($file)")
        echo "STALE    $label"
        continue
    fi
    if swift test >/dev/null 2>&1; then
        survived+=("$label ($file)")
        echo "SURVIVED $label"
    else
        killed=$((killed + 1))
        echo "killed   $label"
    fi
    git checkout -- "$file"
done

total=${#MUTATIONS[@]}
echo
echo "$killed of $total mutations caught by the tests."
for m in ${survived[@]+"${survived[@]}"}; do echo "  survived: $m"; done
for m in ${stale[@]+"${stale[@]}"}; do echo "  no longer applies: $m"; done
[ ${#survived[@]} -eq 0 ] && [ ${#stale[@]} -eq 0 ]
