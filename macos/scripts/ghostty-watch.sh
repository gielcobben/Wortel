#!/usr/bin/env bash
#
# The weekly Ghostty check (.github/workflows/ghostty-watch.yml), in a script
# so it can be run, and dry-run, from a checkout:
#
#   DRY_RUN=1 scripts/ghostty-watch.sh     # say what it would do, change nothing
#
# 1. scripts/ghostty-news.py: what Ghostty changed since the pin that reaches
#    Wortel, and the newest tag past the pin.
# 2. One open issue, found by the marker in its body, holds that report. It is
#    opened when there is something, rewritten each week, commented on (which
#    is what notifies) when a new tag or a security mention appears, and
#    closed when Wortel has caught up.
# 3. The newest tag past the pin gets a draft pull request, branch
#    ghostty/<tag>, that moves ghostty.ref (and zig.version, if the tag needs a
#    newer Zig), and the macos workflow is started on it. A pull request opened
#    with the workflow's own token starts no workflow of its own;
#    workflow_dispatch is the exception. A tag that ever had a pull request,
#    open or closed, never gets another; a branch pushed by a run whose
#    pull request then failed gets its pull request on the next run. Only the
#    newest tag: two tags in one week make one pull request, for the later.
#
# Needs gh with GH_TOKEN (issues, pull requests, contents and actions: write),
# git, python3. Nothing here merges, releases or deploys.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(git rev-parse --show-toplevel)
DRY_RUN=${DRY_RUN:-0}
MARKER="<!-- ghostty-watch"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Writes go through here, so a dry run reads everything and changes nothing.
act() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '[dry run] would run:'
        printf ' %q' "$@" | cut -c1-300
        echo
    else
        "$@"
    fi
}

out="$WORK/outputs"
python3 scripts/ghostty-news.py --github-output "$out" > "$WORK/report.md"
# Read, never sourced: the values come from Ghostty's repository. Each is
# also checked against its shape, so nothing odd reaches git or gh.
get() { sed -n "s/^$1=//p" "$out" | head -1; }
target=$(get target);                 [[ "$target" =~ ^(v|vt-)[0-9]+\.[0-9]+\.[0-9]+$|^$ ]]
target_sha=$(get target_sha);         [[ "$target_sha" =~ ^[0-9a-f]{40}$|^$ ]]
relevant=$(get relevant);             [[ "$relevant" =~ ^[0-9]+$ ]]
relevant_in_target=$(get relevant_in_target); [[ "$relevant_in_target" =~ ^[0-9]+$ ]]
security=$(get security);             [[ "$security" =~ ^[0-9]+$ ]]
zig_min=$(get zig_min);               [[ "$zig_min" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.+]+)?$|^$ ]]
zig_raise=$(get zig_raise);           [[ "$zig_raise" =~ ^(true|false)$ ]]
pin=$(tr -d '[:space:]' < GhosttyKit/ghostty.ref)
echo "[*] pin ${pin:0:9}; newest tag: ${target:-none}; relevant on main: $relevant; security: $security"

# --- the pull request -------------------------------------------------------

pr_url=""
if [ -n "$target" ]; then
    branch="ghostty/$target"
    ever=$(gh pr list --state all --head "$branch" --json url --jq '.[0].url // ""')
    if [ -n "$ever" ]; then
        echo "[*] $target already has a pull request: $ever"
        pr_url=$ever
    else
        pushed=0
        if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
            # An earlier run pushed it and then failed to open the pull request.
            pushed=1
            echo "[*] $branch is pushed but has no pull request; opening it"
        else
            echo "[*] opening a draft pull request for $target"
        fi
        {
            cat <<EOF
Moves Ghostty to **\`$target\`**. Only the pin moved: CI below says whether the
patch stack still applies and the tests pass. Nothing else here is done yet.

To finish it, ask an agent to **"update Ghostty on this pull request"** (the
\`update-ghostty\` skill):

- [ ] The build and every patch apply (CI on this branch)
- [ ] Each change under Links, Config, C API and Ghostty.app below is read, and what changed for Wortel is handled
- [ ] Shell integration fixes ported, terminfo regenerated (if those areas appear)
- [ ] \`scripts/check-terminals.sh\` and \`scripts/verify-agent-status.py\` pass
- [ ] Hand-checked in the built app, as the skill lists

---

EOF
            cat "$WORK/report.md"
        } > "$WORK/pr.md"
        if [ "$DRY_RUN" = 1 ]; then
            if [ "$pushed" = 0 ]; then
                echo "[dry run] would commit ghostty.ref = ${target_sha:0:9}$([ "$zig_raise" = true ] && echo " and zig.version = $zig_min") on $branch and push it"
            fi
            echo "[dry run] would open a draft pull request from $branch and start macos.yml on it. Its body:"
            sed 's/^/    /' "$WORK/pr.md" | head -30
        elif [ "$pushed" = 1 ]; then
            pr_url=$(gh pr create --draft --base main --head "$branch" \
                --title "Ghostty: $target" --body-file "$WORK/pr.md")
            echo "[*] $pr_url"
            gh workflow run macos.yml --ref "$branch"
        else
            git switch --quiet -c "$branch"
            echo "$target_sha" > GhosttyKit/ghostty.ref
            if [ "$zig_raise" = true ]; then
                echo "$zig_min" > GhosttyKit/zig.version
            fi
            git add GhosttyKit/ghostty.ref GhosttyKit/zig.version
            git -c user.name="github-actions[bot]" \
                -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
                commit --quiet -m "Ghostty: Wortel builds $target, not yet reviewed" \
                -m "Moves the pin from ${pin:0:9} to ${target_sha:0:9}. Opened by scripts/ghostty-watch.sh. Only the pin moved; the review, the shell integration, the terminfo and the hand-checks are the update-ghostty skill."
            git push --quiet origin "$branch"
            pr_url=$(gh pr create --draft --base main --head "$branch" \
                --title "Ghostty: $target" --body-file "$WORK/pr.md")
            echo "[*] $pr_url"
            gh workflow run macos.yml --ref "$branch"
            git switch --quiet -
        fi
    fi
fi

# --- the issue --------------------------------------------------------------

# Only this workflow's own issues are looked through, so the report is found
# however many other issues are open.
issue=$(gh issue list --state open --author "app/github-actions" --limit 100 --json number,body \
    --jq "[.[] | select(.body | contains(\"$MARKER\"))][0].number // \"\"")
prev_target=""
prev_security=0
if [ -n "$issue" ]; then
    head=$(gh issue view "$issue" --json body --jq .body | grep -m1 -o "$MARKER[^>]*" || true)
    prev_target=$(sed -n 's/.*target=\([^ ]*\).*/\1/p' <<< "$head")
    prev_security=$(sed -n 's/.*security=\([0-9]*\).*/\1/p' <<< "$head")
    prev_security=${prev_security:-0}
fi

# An advisory the pin lacks keeps the issue open even with no commits to read.
if [ "$relevant" = 0 ] && [ "$security" = 0 ]; then
    if [ -n "$issue" ]; then
        act gh issue comment "$issue" --body "Wortel is level with Ghostty's main branch in everything that reaches it. Closing until there is more."
        act gh issue close "$issue"
    fi
    echo "[*] nothing that reaches Wortel"
    exit 0
fi

if [ "$relevant" = 0 ]; then
    title="Ghostty: a security item Wortel's ${pin:0:9} lacks"
else
    title="Ghostty: $relevant change$([ "$relevant" = 1 ] || echo s) for Wortel since ${pin:0:9}"
fi
[ -n "$target" ] && title="$title (newest tag $target)"
{
    echo "$MARKER target=${target:-none} security=$security -->"
    if [ -n "$pr_url" ]; then
        echo "The draft pull request for \`$target\`: $pr_url"
        echo
    fi
    cat "$WORK/report.md"
} > "$WORK/issue.md"

if [ -z "$issue" ]; then
    act gh issue create --title "$title" --body-file "$WORK/issue.md"
else
    act gh issue edit "$issue" --title "$title" --body-file "$WORK/issue.md"
    news=()
    if [ -n "$target" ] && [ "$target" != "$prev_target" ]; then
        news+=("Ghostty tagged \`$target\`: $relevant_in_target of its changes reach Wortel.${pr_url:+ Draft pull request: $pr_url}")
    fi
    if [ "$security" -gt "$prev_security" ]; then
        news+=("**Security:** $security item(s) now, $prev_security last week. See the top of the report.")
    fi
    if [ ${#news[@]} -gt 0 ]; then
        act gh issue comment "$issue" --body "$(printf '%s\n\n' "${news[@]}")"
    fi
fi
echo "[*] done"
