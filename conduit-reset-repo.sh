#!/usr/bin/env bash
# HARD RESET the repository history to current working tree (baseline).
# This will:
#   - create a brand-new orphan main branch from current state
#   - delete ALL remote tags
#   - delete ALL remote branches except main (optional keep list)
#   - force-push the new main to origin
#
# WARNING: This rewrites public history. Old clones will break.

set -euo pipefail

REMOTE="${REMOTE:-origin}"
BASELINE_BRANCH="${BASELINE_BRANCH:-stable/v0.1.3}"   # your current baseline branch
NEW_MAIN="${NEW_MAIN:-main}"
KEEP_BRANCHES_REGEX="${KEEP_BRANCHES_REGEX:-^(main)$}" # branches to keep on remote

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

need git
need awk
need sed

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repo"
cd "$repo_root"

git remote get-url "$REMOTE" >/dev/null 2>&1 || die "Remote '$REMOTE' not found."

# Fetch everything
git fetch "$REMOTE" --prune --tags

# Ensure baseline branch exists locally
git show-ref --verify --quiet "refs/heads/${BASELINE_BRANCH}" || die "Baseline branch '${BASELINE_BRANCH}' not found locally."

# Checkout baseline
git checkout "$BASELINE_BRANCH"

# Safety snapshot tag locally (not pushed) in case you need emergency restore
snapshot_tag="local-snapshot-$(date +%Y%m%d%H%M%S)"
git tag "$snapshot_tag" >/dev/null 2>&1 || true

# Create orphan main from baseline working tree
git checkout --orphan "$NEW_MAIN"

# Stage everything in working tree (baseline content)
git add -A

# Create single baseline commit
git commit -m "chore: reset repository history; baseline v0.1.3"

# Force-push new main
git push -f "$REMOTE" "$NEW_MAIN:$NEW_MAIN"

# Delete ALL remote tags
remote_tags="$(git ls-remote --tags "$REMOTE" | awk '{print $2}' | sed 's#refs/tags/##' | sed 's/\^{}//' | sort -u)"
if [[ -n "${remote_tags:-}" ]]; then
  echo "$remote_tags" | while read -r t; do
    [[ -z "$t" ]] && continue
    git push "$REMOTE" ":refs/tags/$t" >/dev/null 2>&1 || true
  done
fi

# Optionally delete remote branches (keep only main by default)
remote_branches="$(git ls-remote --heads "$REMOTE" | awk '{print $2}' | sed 's#refs/heads/##')"
echo "$remote_branches" | while read -r b; do
  [[ -z "$b" ]] && continue
  if echo "$b" | grep -Eq "$KEEP_BRANCHES_REGEX"; then
    continue
  fi
  # delete branch
  git push "$REMOTE" --delete "$b" >/dev/null 2>&1 || true
done

echo "OK: Repository reset complete. Remote now contains only '${NEW_MAIN}' with one baseline commit."
echo "NOTE: GitHub Releases are separate objects; delete them via UI or API if needed."
