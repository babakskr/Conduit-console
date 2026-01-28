#!/usr/bin/env bash
# ==============================================================================
# Conduit Console Manager (Native + Docker)
# ------------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Babak Sorkhpour
# Written by Dr. Babak Sorkhpour with help of ChatGPT
#
# Version: 0.1.4
#
# GitHub workflow (recommended):
#   - Keep this file as the single source of truth
#   - Conventional Commits (e.g., "feat(console): add dashboard totals")
#   - Tag releases as vX.Y.Z
#
# Design constraints (from prior incidents):
#   - DO NOT use `set -e` in interactive TUIs (surprise exits)
#   - Menus MUST print selectable lists BEFORE prompting
#   - Native instances MUST use dedicated -d data dir + --stats-file in same dir
# ============================================================================== 

# Interactive-safe strictness: no `set -e`
set -u -o pipefail
IFS=$'\n\t'

APP_NAME="Conduit Console Manager"
APP_VER="0.1.4"

# Upstream conduit repo (for downloads)
CONDUIT_REPO="ssmirr/conduit"

# Paths
UNIT_DIR="/etc/systemd/system"
INSTALL_DIR="/opt/conduit-native"
NATIVE_BIN="${INSTALL_DIR}/conduit"

DATA_ROOT="/var/lib/conduit"     # per-instance data: ${DATA_ROOT}/conduitNNN/
RUN_ROOT="/run/conduit-console"  # ephemeral state if needed

# Dashboard
REFRESH_SECS_DEFAULT=10
REFRESH_SECS="${REFRESH_SECS_DEFAULT}"
NET_IFACE_DEFAULT="eth0"

# Match your naming pattern
SYSTEMD_UNIT_GLOB="conduit*.service"

# ------------------------- UI (colors + helpers) ------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0 || true)"
  C_BOLD="$(tput bold || true)"
  C_DIM="$(tput dim || true)"
  C_RED="$(tput setaf 1 || true)"
  C_GREEN="$(tput setaf 2 || true)"
  C_YELLOW="$(tput setaf 3 || true)"
  C_BLUE="$(tput setaf 4 || true)"
  C_CYAN="$(tput setaf 6 || true)"
  C_GRAY="$(tput setaf 7 || true)"
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_GRAY=""
fi

hr() { printf "%s\n" "${C_BLUE}──────────────────────────────────────────────────────────────────────────────${C_RESET}"; }

header() {
  command -v clear >/dev/null 2>&1 && clear || printf "\033c"
  hr
  printf "%s%s 🚀  %sv%s%s\n" "${C_BOLD}${C_CYAN}" "${APP_NAME}" "${C_DIM}" "${APP_VER}" "${C_RESET}"
  hr
}

pause_enter() { printf "\n"; read -r -p "Press ENTER to continue... " _ </dev/tty || true; }

warn() { printf "%sWARN:%s %s\n" "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
ok()   { printf "%sOK:%s %s\n"   "${C_GREEN}"  "${C_RESET}" "$*"; }
err()  { printf "%sERR:%s %s\n"  "${C_RED}"    "${C_RESET}" "$*" >&2; }

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

need_root() {
  if ! is_root; then
    warn "Run as root: sudo $0"
    return 1
  fi
  return 0
}

has() { command -v "$1" >/dev/null 2>&1; }

# ------------------------- Robust list picker (list-first) --------------------
# Prints list BEFORE prompting. Returns selected item on stdout, empty on back/cancel.
pick_from_list() {
  # IMPORTANT:
  # - This function is commonly used via command substitution: var="$(pick_from_list ...)"
  # - Therefore, ALL menu rendering MUST go to STDERR, and ONLY the selected item is printed to STDOUT.
  local title="${1:-Pick}"
  shift || true
  local -a items=("$@")
  local i

  header >&2
  printf "%s%s%s

" "${C_BOLD}" "${title}" "${C_RESET}" >&2

  if (( ${#items[@]} == 0 )); then
    printf "%s(no items)%s
" "${C_DIM}" "${C_RESET}" >&2
    printf "
" >&2
    read -r -p "Press ENTER to go back... " _ </dev/tty || true
    echo ""
    return 0
  fi

  for i in "${!items[@]}"; do
    printf "  [%d] %s
" "$((i+1))" "${items[$i]}" >&2
  done
  printf "  [0] Back

" >&2

  local choice
  while true; do
    read -r -p "Pick number: " choice </dev/tty || true
    [[ -z "${choice}" ]] && continue
    [[ "${choice}" =~ ^[0-9]+$ ]] || continue
    if (( choice == 0 )); then
      echo ""
      return 0
    fi
    local idx=$((choice-1))
    if (( idx >= 0 && idx < ${#items[@]} )); then
      echo "${items[$idx]}"
      return 0
    fi
  done
}


# ------------------------- Parsing helpers -----------------------------------
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${1:-}"; }

# Converts "676.6 MB" or "676.6MB" into bytes (best-effort, base 1024).
human_to_bytes() {
  local s
  s="$(trim "${1:-0B}")"
  # remove spaces between number and unit
  s="$(sed -E 's/([0-9]) +([A-Za-z])/\1\2/g' <<<"$s")"

  local num unit
  num="$(sed -E 's/^([0-9]+(\.[0-9]+)?).*/\1/' <<<"$s")"
  unit="$(sed -E 's/^[0-9]+(\.[0-9]+)?([A-Za-z]+).*/\2/' <<<"$s")"
  [[ -z "$num" ]] && num="0"
  [[ -z "$unit" ]] && unit="B"

  # normalize unit
  unit="$(tr '[:lower:]' '[:upper:]' <<<"$unit")"
  case "$unit" in
    B)   awk "BEGIN{printf \"%.0f\", $num}" ;;
    KB)  awk "BEGIN{printf \"%.0f\", $num*1024}" ;;
    MB)  awk "BEGIN{printf \"%.0f\", $num*1024*1024}" ;;
    GB)  awk "BEGIN{printf \"%.0f\", $num*1024*1024*1024}" ;;
    TB)  awk "BEGIN{printf \"%.0f\", $num*1024*1024*1024*1024}" ;;
    *)   awk "BEGIN{printf \"%.0f\", $num}" ;;
  esac
}

# Formats bytes to "1.2GB" (no space).
bytes_to_human_nospace() {
  local b="${1:-0}"
  [[ -z "$b" ]] && b=0
  if (( b < 1024 )); then echo "${b}B"; return; fi
  if (( b < 1024*1024 )); then awk "BEGIN{printf \"%.1fKB\", $b/1024}"; return; fi
  if (( b < 1024*1024*1024 )); then awk "BEGIN{printf \"%.1fMB\", $b/1024/1024}"; return; fi
  if (( b < 1024*1024*1024*1024 )); then awk "BEGIN{printf \"%.1fGB\", $b/1024/1024/1024}"; return; fi
  awk "BEGIN{printf \"%.1fTB\", $b/1024/1024/1024/1024}"
}

# Extracts fields from a [STATS] line (journalctl/docker logs), outputs:
# connecting|connected|up_h|down_h|uptime
parse_stats_line() {
  local line="${1:-}"
  local connecting="-" connected="-" up="0B" down="0B" uptime="-"

  connecting="$(sed -nE 's/.*Connecting:[[:space:]]*([0-9]+).*/\1/p' <<<"$line" | tail -n1)"
  connected="$(sed -nE 's/.*Connected:[[:space:]]*([0-9]+).*/\1/p'   <<<"$line" | tail -n1)"
  up="$(sed -nE 's/.*Up:[[:space:]]*([0-9]+(\.[0-9]+)?[[:space:]]*[A-Za-z]+).*/\1/p' <<<"$line" | tail -n1)"
  down="$(sed -nE 's/.*Down:[[:space:]]*([0-9]+(\.[0-9]+)?[[:space:]]*[A-Za-z]+).*/\1/p' <<<"$line" | tail -n1)"
  uptime="$(sed -nE 's/.*Uptime:[[:space:]]*([^|]+).*/\1/p' <<<"$line" | tail -n1)"

  [[ -z "$connecting" ]] && connecting="-"
  [[ -z "$connected"  ]] && connected="-"
  [[ -z "$up" ]] && up="0B"
  [[ -z "$down" ]] && down="0B"
  [[ -z "$uptime" ]] && uptime="-"

  up="$(sed -E 's/([0-9]) +([A-Za-z])/\1\2/g' <<<"$up")"
  down="$(sed -E 's/([0-9]) +([A-Za-z])/\1\2/g' <<<"$down")"
  uptime="$(trim "$uptime")"

  echo "${connecting}|${connected}|${up}|${down}|${uptime}"
}

# ------------------------- systemd (native) -----------------------------------
list_native_loaded_units() {
  systemctl list-units --type=service --all "${SYSTEMD_UNIT_GLOB}" --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | sed '/^$/d' || true
}

unit_state() {
  local u="$1"
  systemctl is-active "$u" 2>/dev/null || echo "unknown"
}

unit_failed_state() {
  local u="$1"
  systemctl is-failed "$u" 2>/dev/null || echo "unknown"
}

unit_execstart() {
  local u="$1"
  systemctl show -p ExecStart --value "$u" 2>/dev/null || true
}

# Extract -m and -b from ExecStart
parse_execstart_mb() {
  local ex="$1"
  local m b
  m="$(sed -nE 's/.*(^|[[:space:]])-m[[:space:]]+([0-9]+).*/\2/p' <<<"$ex" | head -n1)"
  b="$(sed -nE 's/.*(^|[[:space:]])-b[[:space:]]+(-1|[0-9]+(\.[0-9]+)?).*/\2/p' <<<"$ex" | head -n1)"
  [[ -z "$m" ]] && m="-"
  [[ -z "$b" ]] && b="-"
  echo "${m}|${b}"
}

bw_pretty() {
  local b="$1"
  [[ "$b" == "-1" ]] && echo "∞" && return
  echo "$b"
}

last_stats_native() {
  local u="$1"
  journalctl -u "$u" -n 200 --no-pager -o cat 2>/dev/null | grep -F "[STATS]" | tail -n1 || true
}

create_native_unit_file() {
  local unit="$1"
  local max_clients="$2"
  local bandwidth="$3"
  local datadir="$4"
  local statsfile="$5"

  cat > "${UNIT_DIR}/${unit}" <<EOF
[Unit]
Description=Conduit instance ${unit}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NATIVE_BIN} start -m ${max_clients} -b ${bandwidth} -d ${datadir} --stats-file ${statsfile}
WorkingDirectory=${datadir}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

# NOTE: This function MUST NEVER be modified as per project requirement.
# It is intentionally kept identical to the previously working version.
native_create_instance() {
  need_root || return 0
  header
  printf "%sCreate New Native Instance%s\n" "${C_BOLD}" "${C_RESET}"
  printf "%sInstance name pattern:%s conduit<NUM>.service (e.g., conduit250.service)\n\n" "${C_DIM}" "${C_RESET}"

  local num m bw
  while true; do
    read -r -p "Instance number (e.g., 250) (0=Back): " num </dev/tty || true
    [[ "${num:-}" == "0" ]] && return 0
    [[ "${num:-}" =~ ^[0-9]+$ ]] && break
  done

  local unit="conduit${num}.service"
  if systemctl status "$unit" >/dev/null 2>&1; then
    warn "Unit already exists: $unit"
    pause_enter
    return 0
  fi

  read -r -p "Max clients (-m) [default=${num}]: " m </dev/tty || true
  [[ -z "${m}" ]] && m="${num}"
  [[ "${m}" =~ ^[0-9]+$ ]] || { warn "Invalid -m"; pause_enter; return 0; }

  read -r -p "Bandwidth (-b) 2..40 (ENTER=Unlimited -> -1): " bw </dev/tty || true
  if [[ -z "${bw}" ]]; then
    bw="-1"
  else
    [[ "${bw}" =~ ^-1$|^[0-9]+(\.[0-9]+)?$ ]] || { warn "Invalid -b"; pause_enter; return 0; }
  fi

  if [[ ! -x "${NATIVE_BIN}" ]]; then
    warn "Native binary not found at ${NATIVE_BIN}. Install/update it first."
    pause_enter
    return 0
  fi

  local datadir="${DATA_ROOT}/conduit${num}"
  local statsfile="${datadir}/stats.json"
  mkdir -p "${datadir}" "${RUN_ROOT}" >/dev/null 2>&1 || true

  create_native_unit_file "${unit}" "${m}" "${bw}" "${datadir}" "${statsfile}"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "${unit}" >/dev/null 2>&1 || true

  ok "Created and started ${unit} (data: ${datadir})"
  pause_enter
}

systemd_daemon_reload_report() {
  local out rc
  out="$(systemctl daemon-reload 2>&1)"; rc=$?
  if (( rc == 0 )); then
    ok "systemd daemon-reload succeeded."
  else
    err "systemd daemon-reload failed (rc=${rc})."
    [[ -n "$out" ]] && printf "%s\n" "$out"
  fi
  return $rc
}

systemd_unit_report() {
  local unit="$1"
  local last_rc="$2"
  local last_out="$3"

  printf "\n"
  hr
  printf "%sService Report:%s %s\n" "${C_BOLD}" "${C_RESET}" "$unit"
  hr

  if (( last_rc == 0 )); then
    ok "Action completed successfully."
  else
    err "Action failed (rc=${last_rc})."
  fi

  if [[ -n "$last_out" ]]; then
    printf "\n%sOutput:%s\n%s\n" "${C_DIM}" "${C_RESET}" "$last_out"
  fi

  local active sub result
  active="$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || echo "?")"
  sub="$(systemctl show -p SubState --value "$unit" 2>/dev/null || echo "?")"
  result="$(systemctl show -p Result --value "$unit" 2>/dev/null || echo "?")"

  printf "\n%-16s %s\n" "ActiveState:" "$active"
  printf "%-16s %s\n" "SubState:" "$sub"
  printf "%-16s %s\n" "Result:" "$result"

  if (( last_rc != 0 )) || [[ "$active" != "active" ]]; then
    printf "\n%sRecent journal (last 20 lines):%s\n" "${C_DIM}" "${C_RESET}"
    journalctl -u "$unit" -n 20 --no-pager 2>/dev/null || true
  fi
}

native_single_action() {
  need_root || return 0

  # MUST show native list first (handled by pick_from_list)
  local -a units
  mapfile -t units < <(list_native_loaded_units)
  local unit
  unit="$(pick_from_list "Pick native unit" "${units[@]}")"
  [[ -z "${unit}" ]] && return 0

  local action
  action="$(pick_from_list "Action for ${unit}" "start" "stop" "restart" "enable" "disable" "status")"
  [[ -z "${action}" ]] && return 0

  header
  printf "%sNative Action%s\n\n" "${C_BOLD}" "${C_RESET}"
  printf "Unit:   %s\nAction: %s\n\n" "$unit" "$action"

  local out rc

  if [[ "$action" == "status" ]]; then
    systemctl status "$unit" --no-pager
    pause_enter
    return 0
  fi

  # Requirement: after any change, reload systemd and (re-)execute unit action.
  systemd_daemon_reload_report || true

  case "$action" in
    start)
      out="$(systemctl start "$unit" 2>&1)"; rc=$? ;;
    stop)
      out="$(systemctl stop "$unit" 2>&1)"; rc=$? ;;
    restart)
      out="$(systemctl restart "$unit" 2>&1)"; rc=$? ;;
    enable)
      out="$(systemctl enable --now "$unit" 2>&1)"; rc=$? ;;
    disable)
      out="$(systemctl disable --now "$unit" 2>&1)"; rc=$? ;;
    *)
      out="Unknown action"; rc=2 ;;
  esac

  systemd_unit_report "$unit" "$rc" "$out"
  pause_enter
}

native_delete_instance() {
  need_root || return 0

  local -a units
  mapfile -t units < <(list_native_loaded_units)
  local unit
  unit="$(pick_from_list "Pick native unit to DELETE" "${units[@]}")"
  [[ -z "${unit}" ]] && return 0

  local name="${unit%.service}"
  local datadir="${DATA_ROOT}/${name}"
  local unitfile="${UNIT_DIR}/${unit}"

  header
  warn "This will STOP -> DISABLE -> REMOVE:"
  printf "  - %s
  - %s

" "${unitfile}" "${datadir}"

  local confirm
  read -r -p "Type DELETE to confirm: " confirm </dev/tty || true
  [[ "${confirm:-}" != "DELETE" ]] && { ok "Canceled."; pause_enter; return 0; }

  local out="" rc=0

  # Always stop first (requirement)
  out+="$(systemctl stop "${unit}" 2>&1)"; rc=$?

  # Then disable
  out+=$'
'"$(systemctl disable --now "${unit}" 2>&1)"; (( rc == 0 )) || true

  # Remove files
  rm -f "${unitfile}" >/dev/null 2>&1 || true
  rm -rf "${datadir}" >/dev/null 2>&1 || true

  # Reload systemd
  out+=$'
'"$(systemctl daemon-reload 2>&1)"; (( rc == 0 )) || true

  # Report
  printf "
"
  hr
  printf "%sDelete Report:%s %s
" "${C_BOLD}" "${C_RESET}" "${unit}"
  hr

  if [[ -f "${unitfile}" ]]; then
    err "Unit file still exists: ${unitfile}"
  else
    ok "Unit file removed: ${unitfile}"
  fi

  if [[ -d "${datadir}" ]]; then
    err "Data directory still exists: ${datadir}"
  else
    ok "Data directory removed: ${datadir}"
  fi

  if systemctl status "${unit}" >/dev/null 2>&1; then
    warn "systemctl still sees the unit (it may be cached)."
  else
    ok "systemctl no longer reports the unit."
  fi

  if [[ -n "$out" ]]; then
    printf "
%sOutput:%s
%s
" "${C_DIM}" "${C_RESET}" "$out"
  fi

  pause_enter
}


native_view_logs() {
  # Requirement:
  # - Show the service list first
  # - Show ONLY the last 10 log lines (no follow)
  local -a units
  mapfile -t units < <(list_native_loaded_units)
  local unit
  unit="$(pick_from_list "Pick native unit (journalctl last 10)" "${units[@]}")"
  [[ -z "${unit}" ]] && return 0

  header
  printf "%sLast 10 log lines:%s %s

" "${C_BOLD}" "${C_RESET}" "${unit}"
  journalctl -u "${unit}" -n 10 --no-pager 2>/dev/null || true
  pause_enter
}


# ------------------------- Docker ------------------------------------------------

# Docker/Compose configuration
DOCKER_TEMPLATE_DIR="/opt/conduit-docker"               # git clone of upstream docker files
DOCKER_TEMPLATE_GIT_URL="https://github.com/ssmirr/conduit.git"
DOCKER_INSTANCES_ROOT="/opt/conduit-docker-instances"   # per-instance compose projects
DOCKER_UNIT_SUFFIX="-docker.service"                    # e.g., conduit250-docker.service

compose_cmd() {
  # Prefer docker compose plugin; fallback to docker-compose.
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif has docker-compose; then
    echo "docker-compose"
  else
    echo ""
  fi
}

docker_available() { has docker && docker info >/dev/null 2>&1; }

# Backward-compatible helpers required by the Live Dashboard (DO NOT remove):
# - list_docker_conduits
# - docker_state
# - last_stats_docker
list_docker_conduits() {
  # Any container whose name starts with "conduit" is considered relevant.
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i '^conduit' || true
}

docker_state() {
  local c="$1"
  docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "unknown"
}

last_stats_docker() {
  local c="$1"
  docker logs --tail 200 "$c" 2>/dev/null | grep -F "[STATS]" | tail -n1 || true
}

compose_available() {
  local cc
  cc="$(compose_cmd)"
  [[ -n "$cc" ]]
}

ensure_docker_template() {
  # Ensure DOCKER_TEMPLATE_DIR is a git checkout of DOCKER_TEMPLATE_GIT_URL
  # Requirement: before any docker changes, fetch latest from git.
  need_root || return 1
  if ! has git; then err "git is required."; return 1; fi

  if [[ ! -d "${DOCKER_TEMPLATE_DIR}/.git" ]]; then
    mkdir -p "${DOCKER_TEMPLATE_DIR}" >/dev/null 2>&1 || true
    if [[ -z "$(ls -A "${DOCKER_TEMPLATE_DIR}" 2>/dev/null || true)" ]]; then
      ok "Cloning docker template repo into ${DOCKER_TEMPLATE_DIR}..."
      if ! git clone "${DOCKER_TEMPLATE_GIT_URL}" "${DOCKER_TEMPLATE_DIR}" >/dev/null 2>&1; then
        err "git clone failed."
        return 1
      fi
    else
      err "${DOCKER_TEMPLATE_DIR} exists but is not a git repo (and not empty)."
      err "Fix: move it aside or initialize git there."
      return 1
    fi
  fi

  ok "Updating docker template repo (git pull --ff-only)..."
  if ! git -C "${DOCKER_TEMPLATE_DIR}" pull --ff-only >/dev/null 2>&1; then
    err "git pull failed (check local changes / connectivity)."
    return 1
  fi
  return 0
}

docker_update_all_instances() {
  # Requirement: every docker change must refresh from git and then update all services.
  need_root || return 1
  docker_available || { err "Docker not available."; return 1; }
  compose_available || { err "Docker Compose not available (docker compose / docker-compose missing)."; return 1; }

  ensure_docker_template || return 1

  mkdir -p "${DOCKER_INSTANCES_ROOT}" >/dev/null 2>&1 || true

  local cc
  cc="$(compose_cmd)"

  local dir any=0
  for dir in "${DOCKER_INSTANCES_ROOT}"/*; do
    [[ -d "$dir" ]] || continue
    [[ -f "${dir}/docker-compose.yml" ]] || continue
    any=1
    ok "Updating instance: $(basename "$dir")"
    ( cd "$dir" && ${cc} pull >/dev/null 2>&1 || true )
    ( cd "$dir" && ${cc} up -d --build >/dev/null 2>&1 || true )
  done

  if (( any == 0 )); then
    warn "No docker instances found under ${DOCKER_INSTANCES_ROOT}."
  fi
  return 0
}

list_docker_instances() {
  mkdir -p "${DOCKER_INSTANCES_ROOT}" >/dev/null 2>&1 || true
  ls -1 "${DOCKER_INSTANCES_ROOT}" 2>/dev/null | sed '/^$/d' || true
}

instance_unit_name() {
  local inst="$1"
  echo "${inst}${DOCKER_UNIT_SUFFIX}"
}

create_docker_unit_file() {
  local inst="$1"
  local unit
  unit="$(instance_unit_name "$inst")"

  cat > "${UNIT_DIR}/${unit}" <<EOF
[Unit]
Description=Conduit Docker instance ${inst}
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${DOCKER_INSTANCES_ROOT}/${inst}
ExecStart=/usr/bin/env bash -lc '$(compose_cmd) up -d --build'
ExecStop=/usr/bin/env bash -lc '$(compose_cmd) down'
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
}

docker_create_instance() {
  need_root || return 0
  if ! docker_available; then err "Docker not available."; pause_enter; return 0; fi
  if ! compose_available; then err "Docker Compose not available."; pause_enter; return 0; fi

  # Requirement: before changes, fetch latest from git.
  if ! ensure_docker_template; then
    pause_enter
    return 0
  fi

  header
  printf "%sCreate New Docker Instance%s

" "${C_BOLD}" "${C_RESET}"
  printf "%sInstance pattern:%s conduit<NUM> (compose project + systemd unit)

" "${C_DIM}" "${C_RESET}"

  local num
  while true; do
    read -r -p "Instance number (e.g., 250) (0=Back): " num </dev/tty || true
    [[ "${num:-}" == "0" ]] && return 0
    [[ "${num:-}" =~ ^[0-9]+$ ]] && break
  done

  local inst="conduit${num}"
  local dir="${DOCKER_INSTANCES_ROOT}/${inst}"

  if [[ -d "$dir" ]]; then
    warn "Instance directory already exists: $dir"
    pause_enter
    return 0
  fi

  mkdir -p "$dir" >/dev/null 2>&1 || true

  # Copy template compose file
  if [[ ! -f "${DOCKER_TEMPLATE_DIR}/docker-compose.yml" ]]; then
    err "Template docker-compose.yml not found in ${DOCKER_TEMPLATE_DIR}."
    pause_enter
    return 0
  fi

  cp -a "${DOCKER_TEMPLATE_DIR}/docker-compose.yml" "$dir/docker-compose.yml" >/dev/null 2>&1 || true

  # Optional: copy example env if present
  if [[ -f "${DOCKER_TEMPLATE_DIR}/.env" ]]; then
    cp -a "${DOCKER_TEMPLATE_DIR}/.env" "$dir/.env" >/dev/null 2>&1 || true
  fi

  # Create systemd unit for this instance
  create_docker_unit_file "$inst"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "$(instance_unit_name "$inst")" >/dev/null 2>&1 || true

  # Apply updates to all instances (requirement)
  docker_update_all_instances >/dev/null 2>&1 || true

  ok "Created and started docker instance: ${inst}"
  pause_enter
}

docker_single_action() {
  need_root || return 0
  if ! docker_available; then err "Docker not available."; pause_enter; return 0; fi

  # Requirement: fetch latest from git and update all services BEFORE changes
  ensure_docker_template || { pause_enter; return 0; }
  docker_update_all_instances >/dev/null 2>&1 || true

  local -a insts
  mapfile -t insts < <(list_docker_instances)
  local inst
  inst="$(pick_from_list "Pick docker instance" "${insts[@]}")"
  [[ -z "$inst" ]] && return 0

  local action
  action="$(pick_from_list "Action for ${inst}" "start" "stop" "restart" "status")"
  [[ -z "$action" ]] && return 0

  local unit
  unit="$(instance_unit_name "$inst")"

  header
  printf "%sDocker Instance Action%s

" "${C_BOLD}" "${C_RESET}"
  printf "Instance: %s
Unit:     %s
Action:   %s

" "$inst" "$unit" "$action"

  local out rc

  case "$action" in
    start)
      out="$(systemctl start "$unit" 2>&1)"; rc=$? ;;
    stop)
      out="$(systemctl stop "$unit" 2>&1)"; rc=$? ;;
    restart)
      out="$(systemctl restart "$unit" 2>&1)"; rc=$? ;;
    status)
      systemctl status "$unit" --no-pager
      pause_enter
      return 0
      ;;
    *)
      out="Unknown action"; rc=2 ;;
  esac

  systemd_unit_report "$unit" "$rc" "$out"

  # Requirement: update all services after any change
  docker_update_all_instances >/dev/null 2>&1 || true

  pause_enter
}

docker_delete_instance() {
  need_root || return 0
  if ! docker_available; then err "Docker not available."; pause_enter; return 0; fi
  if ! compose_available; then err "Docker Compose not available."; pause_enter; return 0; fi

  # Requirement: fetch latest from git and update all services BEFORE changes
  ensure_docker_template || { pause_enter; return 0; }
  docker_update_all_instances >/dev/null 2>&1 || true

  local -a insts
  mapfile -t insts < <(list_docker_instances)
  local inst
  inst="$(pick_from_list "Pick docker instance to DELETE" "${insts[@]}")"
  [[ -z "$inst" ]] && return 0

  local dir="${DOCKER_INSTANCES_ROOT}/${inst}"
  local unit
  unit="$(instance_unit_name "$inst")"

  header
  warn "This will STOP -> DISABLE -> REMOVE docker instance and volumes:"
  printf "  - Instance: %s
  - Directory: %s
  - Unit: %s

" "$inst" "$dir" "$unit"

  local confirm
  read -r -p "Type DELETE to confirm: " confirm </dev/tty || true
  [[ "${confirm:-}" != "DELETE" ]] && { ok "Canceled."; pause_enter; return 0; }

  local out="" rc=0

  # Always stop first
  out+="$(systemctl stop "$unit" 2>&1)"; rc=$?

  # Disable
  out+=$'
'"$(systemctl disable --now "$unit" 2>&1)"; (( rc == 0 )) || true

  # Compose down with volume removal (physical volumes)
  local cc
  cc="$(compose_cmd)"
  if [[ -d "$dir" && -f "${dir}/docker-compose.yml" ]]; then
    out+=$'
'"$( ( cd "$dir" && ${cc} down -v --remove-orphans ) 2>&1 )"; (( rc == 0 )) || true
  fi

  # Remove unit file and directory
  rm -f "${UNIT_DIR}/${unit}" >/dev/null 2>&1 || true
  rm -rf "${dir}" >/dev/null 2>&1 || true

  out+=$'
'"$(systemctl daemon-reload 2>&1)"; (( rc == 0 )) || true

  printf "
"
  hr
  printf "%sDocker Delete Report:%s %s
" "${C_BOLD}" "${C_RESET}" "$inst"
  hr

  if [[ -f "${UNIT_DIR}/${unit}" ]]; then
    err "Unit file still exists: ${UNIT_DIR}/${unit}"
  else
    ok "Unit file removed: ${UNIT_DIR}/${unit}"
  fi

  if [[ -d "$dir" ]]; then
    err "Instance directory still exists: $dir"
  else
    ok "Instance directory removed: $dir"
  fi

  if [[ -n "$out" ]]; then
    printf "
%sOutput:%s
%s
" "${C_DIM}" "${C_RESET}" "$out"
  fi

  # Requirement: update all services after change
  docker_update_all_instances >/dev/null 2>&1 || true

  pause_enter
}

docker_view_logs_last10() {
  # Requirement: only show last 10 lines (no follow)
  if ! docker_available; then
    err "Docker not available or daemon not running."
    pause_enter
    return 0
  fi

  local cc
  cc="$(compose_cmd)"

  # Prefer managed instances if available
  local -a insts
  mapfile -t insts < <(list_docker_instances)

  local target
  target="$(pick_from_list "Pick docker instance (last 10 logs)" "${insts[@]}")"
  [[ -z "$target" ]] && return 0

  local dir="${DOCKER_INSTANCES_ROOT}/${target}"

  header
  printf "%sLast 10 log lines:%s %s

" "${C_BOLD}" "${C_RESET}" "$target"

  # Compose logs if possible; fallback to docker logs for container name == target
  if [[ -n "$cc" && -d "$dir" && -f "${dir}/docker-compose.yml" ]]; then
    ( cd "$dir" && ${cc} logs --tail 10 2>/dev/null ) || true
  else
    docker logs --tail 10 "$target" 2>/dev/null || true
  fi

  pause_enter
}

# ------------------------- Network throughput (Mbps) ----------------------------- (Mbps) -----------------------------
read_iface_bytes() {
  local ifc="$1"
  local rx_file="/sys/class/net/${ifc}/statistics/rx_bytes"
  local tx_file="/sys/class/net/${ifc}/statistics/tx_bytes"
  if [[ -r "$rx_file" && -r "$tx_file" ]]; then
    local rx tx
    rx="$(cat "$rx_file" 2>/dev/null || echo 0)"
    tx="$(cat "$tx_file" 2>/dev/null || echo 0)"
    echo "${rx}|${tx}"
  else
    echo "0|0"
  fi
}

default_iface() {
  local ifc="${NET_IFACE_DEFAULT}"
  [[ -d "/sys/class/net/${ifc}" ]] && { echo "$ifc"; return; }
  ls -1 /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n1
}

# ------------------------- Install/Update conduit native binary ------------------
arch_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "conduit-linux-amd64" ;;
    aarch64|arm64) echo "conduit-linux-arm64" ;;
    *) echo "" ;;
  esac
}

install_update_native() {
  need_root || return 0
  if ! has curl; then warn "curl is required."; pause_enter; return 0; fi

  local asset
  asset="$(arch_asset)"
  if [[ -z "$asset" ]]; then
    warn "Unsupported arch: $(uname -m)"
    pause_enter
    return 0
  fi

  local url="https://github.com/${CONDUIT_REPO}/releases/latest/download/${asset}"

  header
  printf "%sInstall/Update Native conduit binary%s\n\n" "${C_BOLD}" "${C_RESET}"
  printf "Target: %s\nSource: %s\n\n" "${NATIVE_BIN}" "${url}"

  mkdir -p "${INSTALL_DIR}" >/dev/null 2>&1 || true

  local tmp
  tmp="$(mktemp -t conduit.XXXXXX)"
  if ! curl -fsSL -o "${tmp}" "${url}"; then
    warn "Download failed."
    rm -f "${tmp}" >/dev/null 2>&1 || true
    pause_enter
    return 0
  fi

  chmod +x "${tmp}" >/dev/null 2>&1 || true

  if has file; then
    if ! file "${tmp}" | grep -qi 'ELF'; then
      warn "Downloaded file doesn't look like a Linux ELF binary."
      rm -f "${tmp}" >/dev/null 2>&1 || true
      pause_enter
      return 0
    fi
  fi

  if [[ -f "${NATIVE_BIN}" ]]; then
    cp -a "${NATIVE_BIN}" "${NATIVE_BIN}.bak.$(date +%Y%m%d%H%M%S)" >/dev/null 2>&1 || true
  fi

  mv -f "${tmp}" "${NATIVE_BIN}" >/dev/null 2>&1 || true
  chmod +x "${NATIVE_BIN}" >/dev/null 2>&1 || true

  ok "Installed/updated: ${NATIVE_BIN}"
  pause_enter
}

# ------------------------- Dashboard --------------------------------------------
state_dot() {
  # Args: class (OK|WAIT|ERR)
  local cls="$1"
  case "$cls" in
    OK)   printf "%s●%s" "${C_GREEN}" "${C_RESET}" ;;
    WAIT) printf "%s●%s" "${C_YELLOW}" "${C_RESET}" ;;
    ERR)  printf "%s●%s" "${C_RED}" "${C_RESET}" ;;
    *)    printf "%s●%s" "${C_GRAY}" "${C_RESET}" ;;
  esac
}

classify_stats() {
  # Inputs: running(0/1) failed(0/1) has_stats(0/1) connected(num or -)
  local running="$1" failed="$2" has_stats="$3" connected="$4"

  if (( failed == 1 )); then
    echo "ERR"
    return
  fi

  if (( running == 0 )); then
    echo "ERR"
    return
  fi

  if (( has_stats == 0 )); then
    echo "WAIT"
    return
  fi

  if [[ "$connected" =~ ^[0-9]+$ ]] && (( connected > 0 )); then
    echo "OK"
  else
    echo "WAIT"
  fi
}

dashboard() {
  local ifc
  ifc="$(default_iface)"

  local prev now prev_rx prev_tx now_rx now_tx
  prev="$(read_iface_bytes "${ifc}")"
  prev_rx="${prev%%|*}"; prev_tx="${prev##*|}"

  while true; do
    header

    printf "%sLive Dashboard%s  %s(refresh=%ss, iface=%s)%s\n" \
      "${C_BOLD}" "${C_RESET}" "${C_DIM}" "${REFRESH_SECS}" "${ifc}" "${C_RESET}"

    printf "%sLegend:%s %s (system error / down)   %s (waiting for stats)   %s (connected & active)\n\n" \
      "${C_DIM}" "${C_RESET}" \
      "$(state_dot ERR)" \
      "$(state_dot WAIT)" \
      "$(state_dot OK)"

    # Net Mbps
    now="$(read_iface_bytes "${ifc}")"
    now_rx="${now%%|*}"; now_tx="${now##*|}"
    local d_rx d_tx rx_mbps tx_mbps
    d_rx=$(( now_rx - prev_rx )); d_tx=$(( now_tx - prev_tx ))
    rx_mbps="$(awk "BEGIN{printf \"%.2f\", (${d_rx}*8)/(${REFRESH_SECS}*1000000)}")"
    tx_mbps="$(awk "BEGIN{printf \"%.2f\", (${d_tx}*8)/(${REFRESH_SECS}*1000000)}")"
    prev_rx="$now_rx"; prev_tx="$now_tx"

    printf "NIC %s: RX %s Mbps | TX %s Mbps\n\n" "${ifc}" "${rx_mbps}" "${tx_mbps}"

    # Table header
    printf "%s%-7s %-26s %-5s %-10s %-10s %-10s %-10s %-12s %-6s %-6s%s\n" \
      "${C_BOLD}" \
      "TYPE" "NAME" "STAT" "Connecting" "Connected" "Up" "Down" "Uptime" "-m" "-b" \
      "${C_RESET}"
    hr

    local total_up_b=0 total_down_b=0 total_conn=0 total_conning=0
    local total_ok=0 total_wait=0 total_err=0

    # Native
    local -a units
    mapfile -t units < <(list_native_loaded_units)
    local u
    for u in "${units[@]}"; do
      local st failed ex mb m b line parsed connecting connected up down uptime
      local upb downb has_stats running is_failed cls dot

      st="$(unit_state "$u")"
      failed="$(unit_failed_state "$u")"
      ex="$(unit_execstart "$u")"
      mb="$(parse_execstart_mb "$ex")"
      m="${mb%%|*}"; b="${mb##*|}"

      line="$(last_stats_native "$u")"
      if [[ -n "$line" ]]; then
        has_stats=1
        parsed="$(parse_stats_line "$line")"
        connecting="${parsed%%|*}"; parsed="${parsed#*|}"
        connected="${parsed%%|*}"; parsed="${parsed#*|}"
        up="${parsed%%|*}"; parsed="${parsed#*|}"
        down="${parsed%%|*}"; parsed="${parsed#*|}"
        uptime="${parsed}"
      else
        has_stats=0
        connecting="-"; connected="-"; up="0B"; down="0B"; uptime="-"
      fi

      running=0
      [[ "$st" == "active" ]] && running=1

      is_failed=0
      [[ "$failed" == "failed" ]] && is_failed=1

      cls="$(classify_stats "$running" "$is_failed" "$has_stats" "$connected")"
      dot="$(state_dot "$cls")"

      case "$cls" in
        OK)   total_ok=$((total_ok+1)) ;;
        WAIT) total_wait=$((total_wait+1)) ;;
        ERR)  total_err=$((total_err+1)) ;;
      esac

      upb="$(human_to_bytes "$up")"
      downb="$(human_to_bytes "$down")"

      [[ "$connecting" =~ ^[0-9]+$ ]] && total_conning=$((total_conning + connecting))
      [[ "$connected"  =~ ^[0-9]+$ ]] && total_conn=$((total_conn + connected))
      total_up_b=$((total_up_b + upb))
      total_down_b=$((total_down_b + downb))

      printf "%-7s %-26s %-5s %-10s %-10s %-10s %-10s %-12s %-6s %-6s\n" \
        "native" "${u}" "${dot}" "${connecting}" "${connected}" "${up}" "${down}" "${uptime}" "${m}" "$(bw_pretty "$b")"
    done

    # Docker (optional)
    if docker_available; then
      local -a cs
      mapfile -t cs < <(list_docker_conduits)
      local c
      for c in "${cs[@]}"; do
        local st line parsed connecting connected up down uptime
        local upb downb has_stats running is_failed cls dot

        st="$(docker_state "$c")"

        line="$(last_stats_docker "$c")"
        if [[ -n "$line" ]]; then
          has_stats=1
          parsed="$(parse_stats_line "$line")"
          connecting="${parsed%%|*}"; parsed="${parsed#*|}"
          connected="${parsed%%|*}"; parsed="${parsed#*|}"
          up="${parsed%%|*}"; parsed="${parsed#*|}"
          down="${parsed%%|*}"; parsed="${parsed#*|}"
          uptime="${parsed}"
        else
          has_stats=0
          connecting="-"; connected="-"; up="0B"; down="0B"; uptime="-"
        fi

        running=0
        [[ "$st" == "running" ]] && running=1

        is_failed=0
        [[ "$st" == "dead" || "$st" == "exited" || "$st" == "created" ]] && is_failed=1

        cls="$(classify_stats "$running" "$is_failed" "$has_stats" "$connected")"
        dot="$(state_dot "$cls")"

        case "$cls" in
          OK)   total_ok=$((total_ok+1)) ;;
          WAIT) total_wait=$((total_wait+1)) ;;
          ERR)  total_err=$((total_err+1)) ;;
        esac

        upb="$(human_to_bytes "$up")"
        downb="$(human_to_bytes "$down")"

        [[ "$connecting" =~ ^[0-9]+$ ]] && total_conning=$((total_conning + connecting))
        [[ "$connected"  =~ ^[0-9]+$ ]] && total_conn=$((total_conn + connected))
        total_up_b=$((total_up_b + upb))
        total_down_b=$((total_down_b + downb))

        printf "%-7s %-26s %-5s %-10s %-10s %-10s %-10s %-12s %-6s %-6s\n" \
          "docker" "${c}" "${dot}" "${connecting}" "${connected}" "${up}" "${down}" "${uptime}" "-" "-"
      done
    fi

    hr

    printf "%sTOTAL:%s Services=%s  %sOK=%s%s  %sWAIT=%s%s  %sERR/DOWN=%s%s\n" \
      "${C_BOLD}" "${C_RESET}" "$((total_ok + total_wait + total_err))" \
      "${C_GREEN}" "$total_ok" "${C_RESET}" \
      "${C_YELLOW}" "$total_wait" "${C_RESET}" \
      "${C_RED}" "$total_err" "${C_RESET}"

    printf "Totals: Connecting=%s  Connected=%s  Up=%s  Down=%s\n" \
      "${total_conning}" "${total_conn}" "$(bytes_to_human_nospace "$total_up_b")" "$(bytes_to_human_nospace "$total_down_b")"

    printf "\n%sPress ENTER or 0 to return. Auto-refresh continues...%s\n" "${C_DIM}" "${C_RESET}"

    local key=""
    local t_end=$((SECONDS + REFRESH_SECS))
    while (( SECONDS < t_end )); do
      IFS= read -r -t 0.2 -n 1 key </dev/tty || true
      if [[ "$key" == "0" || "$key" == $'\n' || "$key" == $'\r' ]]; then
        return 0
      fi
    done
  done
}

# ------------------------- Menus ------------------------------------------------
menu_native() {
  while true; do
    header
    printf "%sNative (systemd) Menu%s\n\n" "${C_BOLD}" "${C_RESET}"
    echo "1) Create native instance (conduit<NUM>.service)"
    echo "2) Start/Stop/Restart/Enable/Disable (single)"
    echo "3) Delete native instance (FULL remove)"
    echo "4) Follow native logs (journalctl -f)"
    echo "0) Back"
    echo
    local c
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) native_create_instance ;;
      2) native_single_action ;;
      3) native_delete_instance ;;
      4) native_view_logs ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

menu_docker() {
  while true; do
    header
    printf "%sDocker Menu%s

" "${C_BOLD}" "${C_RESET}"
    echo "1) Create docker instance (compose + systemd)"
    echo "2) Start/Stop/Restart (single instance)"
    echo "3) Delete docker instance (container + unit + volumes + dir)"
    echo "4) Show last 10 docker log lines"
    echo "5) Update all docker instances (git pull + compose up -d --build)"
    echo "0) Back"
    echo
    local c
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) docker_create_instance ;;
      2) docker_single_action ;;
      3) docker_delete_instance ;;
      4) docker_view_logs_last10 ;;
      5)
        need_root || { pause_enter; continue; }
        ensure_docker_template || { pause_enter; continue; }
        docker_update_all_instances
        pause_enter
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}


main_menu() {
  mkdir -p "${RUN_ROOT}" >/dev/null 2>&1 || true

  while true; do
    header
    echo "1) Live Dashboard (Native + Docker + Totals)"
    echo "2) Install/Update Native conduit (latest GitHub release)"
    echo "3) Native (systemd) management"
    echo "4) Docker management"
    echo "5) Settings (refresh seconds / net iface)"
    echo "0) Exit"
    echo
    local c
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) dashboard ;;
      2) install_update_native ;;
      3) menu_native ;;
      4) menu_docker ;;
      5)
        header
        read -r -p "Refresh seconds [current=${REFRESH_SECS}]: " r </dev/tty || true
        [[ -n "${r:-}" && "${r}" =~ ^[0-9]+$ && "${r}" -ge 1 ]] && REFRESH_SECS="${r}"
        read -r -p "Net iface [current=$(default_iface)]: " ni </dev/tty || true
        [[ -n "${ni:-}" ]] && NET_IFACE_DEFAULT="${ni}"
        ok "Settings updated."
        pause_enter
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

# ------------------------- Entry ------------------------------------------------
main_menu
