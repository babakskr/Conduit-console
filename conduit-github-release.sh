#!/usr/bin/env bash
# Conduit Console - one-shot: commit + tag + GitHub release (fully automated)
# Requirements:
#   - git remote 'origin' exists
#   - GitHub CLI 'gh' installed + authenticated (gh auth login)
#
# Usage:
#   ./conduit-github-release.sh            # default bump = patch
#   ./conduit-github-release.sh patch|minor|major

set -euo pipefail

BUMP_KIND="${1:-patch}"     # patch|minor|major
REMOTE="${REMOTE:-origin}"

die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

need_cmd git
need_cmd sed
need_cmd awk

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository"
cd "$repo_root"

# --- Ensure origin exists
git remote get-url "$REMOTE" >/dev/null 2>&1 || die "Remote '$REMOTE' not found. Set it first."

# --- Ensure gh exists + authed
need_cmd gh
gh auth status >/dev/null 2>&1 || die "GitHub CLI not authenticated. Run: gh auth login"

# --- Maintain .gitignore (idempotent)
touch .gitignore
add_ignore_line() { grep -qxF "$1" .gitignore 2>/dev/null || echo "$1" >> .gitignore; }

add_ignore_line ""
add_ignore_line "# Local/generated artifacts"
add_ignore_line "*.bak"
add_ignore_line "conduit-console.bak"
add_ignore_line "conduit-console.config.json"
add_ignore_line "docker-instances/"
add_ignore_line ".DS_Store"

# --- Find last SemVer tag vX.Y.Z
last_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1 || true)"
prev_tag="$last_tag"

if [[ -z "${last_tag:-}" ]]; then
  major=0; minor=1; patch=0
  prev_tag=""
else
  major="$(echo "$last_tag" | sed -E 's/^v([0-9]+)\..*$/\1/')"
  minor="$(echo "$last_tag" | sed -E 's/^v[0-9]+\.([0-9]+)\..*$/\1/')"
  patch="$(echo "$last_tag" | sed -E 's/^v[0-9]+\.[0-9]+\.([0-9]+)$/\1/')"
fi

case "$BUMP_KIND" in
  patch) patch=$((patch+1));;
  minor) minor=$((minor+1)); patch=0;;
  major) major=$((major+1)); minor=0; patch=0;;
  *) die "Unknown bump kind '$BUMP_KIND'. Use patch|minor|major";;
esac

new_tag="v${major}.${minor}.${patch}"

# --- Optional: update internal version markers (filenames never include version)
update_version_in_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  # APP_VER="x" / VERSION="x"  -> replace with new version (without leading v)
  sed -i -E "s/^(APP_VER|VERSION)=(\"|')([^\"']*)(\"|')/\1=\2${new_tag#v}\4/" "$f" || true
}
update_version_in_file "conduit-console.sh"
update_version_in_file "conduit-git-info.sh"

# --- Stage ONLY what we want in the repo
# Keep it strict: do not stage docker-instances/ or local generated files.
git add .gitignore conduit-console.sh conduit-git-info.sh conduit-github-release.sh 2>/dev/null || true

# If nothing staged, exit
git diff --cached --quiet && die "No staged changes. Edit files or ensure they exist, then rerun."

# --- Commit
git commit -m "release: ${new_tag}"

# --- Tag (annotated)
git rev-parse "$new_tag" >/dev/null 2>&1 && die "Tag ${new_tag} already exists."
git tag -a "$new_tag" -m "Conduit Console ${new_tag}"

# --- Push branch + tags
branch="$(git rev-parse --abbrev-ref HEAD)"
git push "$REMOTE" "$branch"
git push "$REMOTE" --tags

# --- Generate release notes from commit subjects
notes=""
if [[ -n "${prev_tag:-}" ]]; then
  notes="$(git log "${prev_tag}..HEAD" --pretty=format:'- %s (%h)' | sed '/^\s*$/d')"
else
  notes="$(git log -n 50 --pretty=format:'- %s (%h)' | sed '/^\s*$/d')"
fi
[[ -z "${notes:-}" ]] && notes="- Automated release ${new_tag}"

# --- Create GitHub release
gh release create "$new_tag" --title "$new_tag" --notes "$notes" --latest

echo "OK: Published ${new_tag} (commit + tag + GitHub release) on ${REMOTE}/${branch}"
