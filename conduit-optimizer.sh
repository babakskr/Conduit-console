#!/usr/bin/env bash
# ==============================================================================
# Component: Conduit Resource Optimizer (Parallel)
# Original Author: Babak Sorkhpour
# Refactor: Conduit-console maintainer (production hardening)
# Version: 2.1
# License: MIT (project-consistent; adjust if repository uses different license)
# ------------------------------------------------------------------------------
# Description:
#   Production-ready optimizer that adjusts CPU priority (renice) and I/O priority
#   (ionice) for:
#     1) Docker containers whose name/image matches a target keyword
#     2) Native processes (pgrep -f) matching the same keyword
#
# Key Features:
#   - Parallel execution with a concurrency limit (semaphore via wait -n)
#   - Thread-safe/atomic logging (portable lock-dir mutex; no extra deps)
#   - Strict mode + input validation + graceful handling of PID races
#   - No configuration dependencies; all options via CLI
#
# NOTE:
#   - Requires Bash 4.3+ for 'wait -n'.
#   - Must run as root (renice/ionice).
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------ Defaults --------------------------------------
TARGET_KEYWORD="conduit"
DEFAULT_DOCKER_PRI=10
DEFAULT_NATIVE_PRI=15
INPUT_DOCKER_PRI=-1
INPUT_NATIVE_PRI=-1
VERBOSE=0
JOBS=10
DRY_RUN=0

# Best Effort / High I/O priority
TARGET_IONICE_CLASS=2
TARGET_IONICE_LEVEL=0

# Colors (used only for terminal output)
# (Keep simple; do not rely on tput in non-interactive shells)
CLR_GREEN='\033[0;32m'
CLR_YELLOW='\033[1;33m'
CLR_RED='\033[0;31m'
CLR_CYAN='\033[0;36m'
CLR_NC='\033[0m'

# Mutex for thread-safe output
LOCK_DIR="/tmp/conduit-optimizer.lock"

# ------------------------------ Helpers ---------------------------------------
_die() {
  printf '%b[ERROR]%b %s\n' "$CLR_RED" "$CLR_NC" "$*" >&2
  exit 1
}

_info() {
  if [[ $VERBOSE -eq 1 ]]; then
    printf '%b[INFO]%b %s\n' "$CLR_CYAN" "$CLR_NC" "$*" >&2
  fi
}

# Portable mutex using mkdir (atomic on POSIX filesystems)
_lock() {
  local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # Backoff to reduce contention
    ((i++)) || true
    # 0.01 .. 0.10s
    sleep "0.0$(( (i % 10) + 1 ))"
  done
}

_unlock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

_log_line() {
  # Ensure each line prints atomically even under concurrency.
  _lock
  printf '%s\n' "$*"
  _unlock
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || _die "Required command not found: $1"
}

show_version() {
  echo "Conduit Resource Optimizer (Parallel) v2.1"
}

show_help() {
  cat <<'H'
Conduit Resource Optimizer (Parallel) v2.1

Description:
  Adjust CPU (nice/renice) and I/O (ionice) priorities for Docker containers and
  native processes that match a target keyword.

Usage:
  sudo conduit-optimizer_parallel_v2.1.sh [OPTIONS]

Options:
  (No args)         Auto-mode: Docker=10, Native=15
  -dock <5-20|0>    Priority for Docker containers. 5=max perf, 10=high, 20=normal.
                    Use 0 to skip Docker optimization.
  -srv  <5-20|0>    Priority for native processes (same scale). Use 0 to skip.
  -name <KEYWORD>   Target keyword to match (default: conduit)
  -j    <N>         Max concurrent jobs (default: 10)
  -n                Dry-run (print what would change, do not apply)
  -v                Verbose logging
  -ver              Show version and exit
  -h                Show this help

Examples:
  # Auto-mode (recommended)
  sudo conduit-optimizer_parallel_v2.1.sh

  # Aggressive Docker, normal native, 20 parallel workers
  sudo conduit-optimizer_parallel_v2.1.sh -dock 5 -srv 20 -j 20

  # Only native services (skip Docker)
  sudo conduit-optimizer_parallel_v2.1.sh -dock 0 -srv 10
H
}

calc_nice_from_pri() {
  # Map 5..20 to nice -15..0 (same as original: pri-20)
  local pri="$1"
  echo $(( pri - 20 ))
}

validate_pri() {
  local val="$1" name="$2"
  if [[ "$val" -ne 0 ]]; then
    [[ "$val" -ge 5 && "$val" -le 20 ]] || _die "$name priority must be 5..20 or 0 (skip). Got: $val"
  fi
}

is_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]]
}

# Concurrency gate using wait -n
_wait_slot() {
  while (( $(jobs -pr | wc -l) >= JOBS )); do
    wait -n || true
  done
}

# -------------------------- Optimization logic --------------------------------
optimize_pid() {
  # Args: kind label pid nice ionice_class ionice_level
  local kind="$1" label="$2" pid="$3" nice_val="$4" iclass="$5" ilevel="$6"

  # PID may disappear; handle silently
  if ! kill -0 "$pid" 2>/dev/null; then
    _log_line "[${kind}] ${label} (PID ${pid}) -> vanished (skip)"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    _log_line "[${kind}] ${label} (PID ${pid}) -> DRY-RUN: renice ${nice_val}, ionice -c ${iclass} -n ${ilevel}"
    return 0
  fi

  # renice / ionice can fail if PID exits or perms; suppress ugly output
  renice -n "$nice_val" -p "$pid" >/dev/null 2>&1 || {
    _log_line "[${kind}] ${label} (PID ${pid}) -> renice failed (race/perm)"
    return 0
  }

  ionice -c "$iclass" -n "$ilevel" -p "$pid" >/dev/null 2>&1 || {
    _log_line "[${kind}] ${label} (PID ${pid}) -> ionice failed (race/perm)"
    return 0
  }

  _log_line "[${kind}] ${label} (PID ${pid}) -> OK"
}

get_docker_targets() {
  # Output lines: "<CID> <CNAME>"
  docker ps --format '{{.ID}} {{.Names}} {{.Image}}' 2>/dev/null \
    | awk -v k="$TARGET_KEYWORD" 'BEGIN{IGNORECASE=1} $0 ~ k {print $1" "$2}'
}

docker_pid_for_cid() {
  local cid="$1"
  docker inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null || true
}

optimize_docker_all() {
  local pri="$1"
  local nice_val
  nice_val="$(calc_nice_from_pri "$pri")"
  _info "Docker PRI=${pri} -> nice=${nice_val}"

  local line cid cname pid
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    cid="${line%% *}"
    cname="${line#* }"

    pid="$(docker_pid_for_cid "$cid")"
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || {
      _log_line "[Docker] ${cname} (${cid}) -> PID not found (skip)"
      continue
    }

    _wait_slot
    ( optimize_pid "Docker" "$cname" "$pid" "$nice_val" "$TARGET_IONICE_CLASS" "$TARGET_IONICE_LEVEL" ) &
  done < <(get_docker_targets)
}

get_native_pids() {
  # pgrep -f matches keyword in full command line
  pgrep -f "$TARGET_KEYWORD" 2>/dev/null || true
}

native_label_for_pid() {
  local pid="$1"
  # Try to get a readable command (safe)
  local cmd
  cmd="$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '\r' || true)"
  [[ -n "$cmd" ]] && printf '%s' "$cmd" || printf 'pid-%s' "$pid"
}

optimize_native_all() {
  local pri="$1"
  local nice_val
  nice_val="$(calc_nice_from_pri "$pri")"
  _info "Native PRI=${pri} -> nice=${nice_val}"

  local pid label
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue

    # Avoid optimizing ourselves
    if [[ "$pid" -eq "$$" ]]; then
      continue
    fi

    label="$(native_label_for_pid "$pid")"

    _wait_slot
    ( optimize_pid "Native" "$label" "$pid" "$nice_val" "$TARGET_IONICE_CLASS" "$TARGET_IONICE_LEVEL" ) &
  done < <(get_native_pids)
}

# ------------------------------ Arg parsing -----------------------------------
if [[ $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -dock) INPUT_DOCKER_PRI="${2:-}"; shift 2 ;;
      -srv)  INPUT_NATIVE_PRI="${2:-}"; shift 2 ;;
      -name) TARGET_KEYWORD="${2:-}"; shift 2 ;;
      -j)    JOBS="${2:-}"; shift 2 ;;
      -n)    DRY_RUN=1; shift ;;
      -v)    VERBOSE=1; shift ;;
      -ver)  show_version; exit 0 ;;
      -h|--help) show_help; exit 0 ;;
      *) _die "Unknown option: $1 (use -h)" ;;
    esac
  done
fi

# ------------------------------ Validate --------------------------------------
[[ -n "$TARGET_KEYWORD" ]] || _die "Target keyword is empty"
[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 && "$JOBS" -le 200 ]] || _die "-j must be 1..200"

# Auto-mode
if [[ $INPUT_DOCKER_PRI -eq -1 && $INPUT_NATIVE_PRI -eq -1 ]]; then
  INPUT_DOCKER_PRI=$DEFAULT_DOCKER_PRI
  INPUT_NATIVE_PRI=$DEFAULT_NATIVE_PRI
  _log_line "${CLR_GREEN}>> Auto-Mode: Docker=${INPUT_DOCKER_PRI} Native=${INPUT_NATIVE_PRI} Target='${TARGET_KEYWORD}'${CLR_NC}"
else
  [[ $INPUT_DOCKER_PRI -eq -1 ]] && INPUT_DOCKER_PRI=0
  [[ $INPUT_NATIVE_PRI -eq -1 ]] && INPUT_NATIVE_PRI=0
  _log_line "${CLR_GREEN}>> Manual-Mode: Docker=${INPUT_DOCKER_PRI} Native=${INPUT_NATIVE_PRI} Target='${TARGET_KEYWORD}'${CLR_NC}"
fi

validate_pri "$INPUT_DOCKER_PRI" "Docker"
validate_pri "$INPUT_NATIVE_PRI" "Native"

is_root || _die "Root privileges required. Run with sudo."

# Command checks
require_cmd renice
require_cmd ionice
# Docker optional only if docker phase enabled
if [[ $INPUT_DOCKER_PRI -gt 0 ]]; then
  require_cmd docker
fi
require_cmd ps
require_cmd pgrep

# ------------------------------ Run -------------------------------------------
_log_line "---------------------------------------------------"
_log_line "Starting Optimizer (jobs=${JOBS}, dry_run=${DRY_RUN})"
_log_line "---------------------------------------------------"

if [[ $INPUT_DOCKER_PRI -gt 0 ]]; then
  optimize_docker_all "$INPUT_DOCKER_PRI"
else
  _log_line "[Docker] skipped"
fi

if [[ $INPUT_NATIVE_PRI -gt 0 ]]; then
  optimize_native_all "$INPUT_NATIVE_PRI"
else
  _log_line "[Native] skipped"
fi

# Wait all background jobs
wait || true

_log_line "---------------------------------------------------"
_log_line "${CLR_GREEN}>> Optimization Complete.${CLR_NC}"

exit 0
