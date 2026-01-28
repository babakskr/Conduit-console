#!/usr/bin/env bash
# ==============================================================================
# Conduit Upstream + Repo Quick-Intel
# ------------------------------------------------------------------------------
# Purpose:
#   - Pull latest Conduit Docker image (GHCR)
#   - Show latest Conduit GitHub release tag (best-effort)
#   - Show local native conduit version (if installed)
#   - Show local console repo status (if this script is inside the repo)
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Babak Sorkhpour
# ==============================================================================

set -u -o pipefail
IFS=$'\n\t'

CONDUIT_REPO="ssmirr/conduit"
DOCKER_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"
CONSOLE_REMOTE="https://github.com/babakskr/Conduit-console.git"

has() { command -v "$1" >/dev/null 2>&1; }

hr() { printf "%s\n" "--------------------------------------------------------------------------------"; }

note() { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*" >&2; }
err()  { printf "[ERR ] %s\n" "$*" >&2; }

latest_release_tag() {
  # Uses GitHub API. If rate-limited, returns empty.
  has curl || return 0
  local api="https://api.github.com/repos/${CONDUIT_REPO}/releases/latest"
  local tag=""
  if has jq; then
    tag="$(curl -fsSL "$api" | jq -r '.tag_name // empty' 2>/dev/null || true)"
  else
    tag="$(curl -fsSL "$api" | grep -Eo '"tag_name"\s*:\s*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  fi
  printf "%s" "$tag"
}

show_native_version() {
  if has conduit; then
    note "Native conduit: $(conduit --version 2>/dev/null | head -n1)"
  else
    warn "Native conduit not found in PATH."
  fi
}

pull_docker_latest() {
  has docker || { err "docker not found."; return 1; }
  note "Pulling Docker image: ${DOCKER_IMAGE}"
  docker pull "${DOCKER_IMAGE}"
}

show_docker_image() {
  has docker || return 0
  note "Docker image (local):"
  docker image ls --digests "${DOCKER_IMAGE}" 2>/dev/null || true
}

show_console_repo_status() {
  if ! has git; then warn "git not found."; return 0; fi
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    note "Console repo: $(git rev-parse --show-toplevel)"
    note "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
    note "Last commit: $(git log -1 --oneline 2>/dev/null || true)"
    hr
    git status -sb || true
    hr
    if ! git remote get-url origin >/dev/null 2>&1; then
      warn "origin remote not set. Suggested:"
      echo "  git remote add origin ${CONSOLE_REMOTE}"
    else
      note "origin: $(git remote get-url origin 2>/dev/null || true)"
    fi
  else
    warn "Not inside a git work tree; skipping console repo status."
  fi
}

main() {
  hr
  note "Conduit upstream release (best-effort)..."
  local tag
  tag="$(latest_release_tag)"
  if [[ -n "$tag" ]]; then
    note "Latest upstream release tag: ${tag}"
  else
    warn "Could not fetch latest tag (no curl/jq, or API rate-limit)."
  fi

  hr
  show_native_version

  hr
  show_docker_image

  hr
  pull_docker_latest || true

  hr
  show_console_repo_status
  hr
  note "Done."
}

main "$@"
