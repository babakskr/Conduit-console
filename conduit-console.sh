#!/usr/bin/env bash
# ==============================================================================
# Conduit Console Manager (Native + Docker) - Main Console
# ------------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Babak Sorkhpour
# Written by Dr. Babak Sorkhpour with help of ChatGPT
#
# Version: 0.2.18
#
# Key rules:
# - Interactive TUI: DO NOT use `set -e`
# - Menus MUST print selectable lists BEFORE prompting
# - Lists used via $(...) MUST print UI to STDERR, selection to STDOUT
# - Native "Create" flow must remain functional and stable
# - Docker: NO docker-compose; ALWAYS use :latest
# - Settings are stored in JSON next to this console script
# - Health check is delegated to a sub-script (to be implemented next)
# ==============================================================================

set -u -o pipefail
IFS=$'\n\t'

APP_NAME="Conduit Console Manager"
APP_VER="0.2.1"

# ------------------------- Paths (console-local) -------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"

CONFIG_FILE="${SCRIPT_DIR}/conduit-console.config.json"
HEALTH_SCRIPT="${SCRIPT_DIR}/conduit-health.sh"          # sub-script (to be created next)
DOCKER_INSTANCES_DIR="${SCRIPT_DIR}/docker-instances"    # per-instance docker configs (console-local)

# system paths
UNIT_DIR="/etc/systemd/system"
INSTALL_DIR="/opt/conduit-native"
NATIVE_BIN="${INSTALL_DIR}/conduit"
DATA_ROOT="/var/lib/conduit"
RUN_ROOT="/run/conduit-console"

CONDUIT_REPO="ssmirr/conduit"

# Docker image (always latest)
DOCKER_IMAGE="ghcr.io/ssmirr/conduit/conduit:latest"

SYSTEMD_UNIT_GLOB="conduit*.service"

# ------------------------- Defaults (overridden by config) ---------------------
REFRESH_SECS_DEFAULT=10
NET_IFACE_DEFAULT="eth0"
LOG_TAIL_DEFAULT=10

CFG_REFRESH_SECS="${REFRESH_SECS_DEFAULT}"
CFG_NET_IFACE="${NET_IFACE_DEFAULT}"
CFG_LOG_TAIL="${LOG_TAIL_DEFAULT}"
CFG_COLOR="true"

# last health snapshot (stored in config json)
CFG_HEALTH_LAST_RUN=""
CFG_HEALTH_OK="false"
CFG_HEALTH_SUMMARY=""

# ------------------------- UI (colors + helpers) ------------------------------
has() { command -v "$1" >/dev/null 2>&1; }

init_colors() {
  if [[ "${CFG_COLOR}" == "true" && -t 1 && -t 2 ]] && has tput; then
    C_RESET="$(tput sgr0 || true)"
    C_BOLD="$(tput bold || true)"
    C_DIM="$(tput dim || true)"
    C_RED="$(tput setaf 1 || true)"
    C_GREEN="$(tput setaf 2 || true)"
    C_YELLOW="$(tput setaf 3 || true)"
    C_BLUE="$(tput setaf 4 || true)"
    C_CYAN="$(tput setaf 6 || true)"
    C_WHITE="$(tput setaf 7 || true)"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_WHITE=""
  fi
}

hr() { printf "%s\n" "${C_BLUE}──────────────────────────────────────────────────────────────────────────────${C_RESET}"; }

header() {
  has clear && clear || printf "\033c"
  hr
  printf "%s%s 🚀  %sv%s%s\n" "${C_BOLD}${C_CYAN}" "${APP_NAME}" "${C_DIM}" "${APP_VER}" "${C_RESET}"
  hr
}

warn() { printf "%sWARN:%s %s\n" "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf "%sERR:%s %s\n"  "${C_RED}"    "${C_RESET}" "$*" >&2; }
ok()   { printf "%sOK:%s %s\n"   "${C_GREEN}"  "${C_RESET}" "$*"; }
info() { printf "%s[INFO]%s %s\n" "${C_CYAN}" "${C_RESET}" "$*"; }

pause_enter() { printf "\n"; read -r -p "Press ENTER to continue... " _ </dev/tty || true; }

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

need_root() {
  if ! is_root; then
    warn "Run as root: sudo $0"
    return 1
  fi
  return 0
}

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${1:-}"; }

# ------------------------- Robust list picker (list-first) --------------------
# Prints UI to STDERR; prints selection to STDOUT.
pick_from_list() {
  local title="${1:-Pick}"
  shift || true
  local -a items=("$@")

  header >&2
  printf "%s%s%s\n\n" "${C_BOLD}" "${title}" "${C_RESET}" >&2

  if (( ${#items[@]} == 0 )); then
    printf "%s(no items)%s\n\n" "${C_DIM}" "${C_RESET}" >&2
    read -r -p "Press ENTER to go back... " _ </dev/tty || true
    echo ""
    return 0
  fi

  local i
  for i in "${!items[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${items[$i]}" >&2
  done
  printf "  [0] Back\n\n" >&2

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

# ------------------------- JSON config (console-local) -------------------------
config_write_default() {
  cat > "${CONFIG_FILE}" <<EOF
{
  "network": {
    "iface": "${NET_IFACE_DEFAULT}"
  },
  "console": {
    "refresh_seconds": ${REFRESH_SECS_DEFAULT},
    "log_tail_lines": ${LOG_TAIL_DEFAULT},
    "color": true
  },
  "health": {
    "last_run": "",
    "ok": false,
    "summary": ""
  }
}
EOF
}

config_load() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    config_write_default
  fi

  # If jq exists, use it. Otherwise keep defaults and warn (Health script can install jq later).
  if has jq; then
    local iface refresh tail color
    iface="$(jq -r '.network.iface // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    refresh="$(jq -r '.console.refresh_seconds // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    tail="$(jq -r '.console.log_tail_lines // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    color="$(jq -r '.console.color // empty' "${CONFIG_FILE}" 2>/dev/null || true)"

    [[ -n "${iface}" && "${iface}" != "null" ]] && CFG_NET_IFACE="${iface}"
    [[ -n "${refresh}" && "${refresh}" != "null" ]] && CFG_REFRESH_SECS="${refresh}"
    [[ -n "${tail}" && "${tail}" != "null" ]] && CFG_LOG_TAIL="${tail}"
    if [[ "${color}" == "true" || "${color}" == "false" ]]; then
      CFG_COLOR="${color}"
    fi

    CFG_HEALTH_LAST_RUN="$(jq -r '.health.last_run // ""' "${CONFIG_FILE}" 2>/dev/null || true)"
    CFG_HEALTH_OK="$(jq -r '.health.ok // false' "${CONFIG_FILE}" 2>/dev/null || true)"
    CFG_HEALTH_SUMMARY="$(jq -r '.health.summary // ""' "${CONFIG_FILE}" 2>/dev/null || true)"
  else
    # no jq, keep defaults; minimal parse for iface/refresh if present
    warn "jq not found. Settings edits require jq (Health script can install it)."
  fi
}

config_save_network_iface() {
  local iface="$1"
  has jq || { err "jq is required to edit JSON config. Run Health -> Install jq."; return 1; }
  tmp="$(mktemp -t conduitcfg.XXXXXX)"
  jq --arg v "$iface" '.network.iface=$v' "${CONFIG_FILE}" > "$tmp" && mv -f "$tmp" "${CONFIG_FILE}"
}

config_save_console_refresh() {
  local refresh="$1"
  has jq || { err "jq is required to edit JSON config. Run Health -> Install jq."; return 1; }
  tmp="$(mktemp -t conduitcfg.XXXXXX)"
  jq --argjson v "$refresh" '.console.refresh_seconds=$v' "${CONFIG_FILE}" > "$tmp" && mv -f "$tmp" "${CONFIG_FILE}"
}

config_save_console_logtail() {
  local tail="$1"
  has jq || { err "jq is required to edit JSON config. Run Health -> Install jq."; return 1; }
  tmp="$(mktemp -t conduitcfg.XXXXXX)"
  jq --argjson v "$tail" '.console.log_tail_lines=$v' "${CONFIG_FILE}" > "$tmp" && mv -f "$tmp" "${CONFIG_FILE}"
}

config_save_console_color() {
  local color_bool="$1" # true|false
  has jq || { err "jq is required to edit JSON config. Run Health -> Install jq."; return 1; }
  tmp="$(mktemp -t conduitcfg.XXXXXX)"
  jq --argjson v "$color_bool" '.console.color=$v' "${CONFIG_FILE}" > "$tmp" && mv -f "$tmp" "${CONFIG_FILE}"
}

config_save_health_snapshot() {
  local ok_bool="$1"   # true|false
  local summary="$2"
  local ts
  ts="$(date -Is 2>/dev/null || date)"

  has jq || return 0
  tmp="$(mktemp -t conduitcfg.XXXXXX)"
  jq --arg ts "$ts" --argjson ok "$ok_bool" --arg sum "$summary" \
     '.health.last_run=$ts | .health.ok=$ok | .health.summary=$sum' \
     "${CONFIG_FILE}" > "$tmp" && mv -f "$tmp" "${CONFIG_FILE}"
}

# ------------------------- Preflight (minimal + delegated) ----------------------
preflight_minimal() {
  local ok_all="true"
  local missing=()

  for c in bash systemctl journalctl awk sed grep; do
    if ! has "$c"; then
      ok_all="false"
      missing+=("$c")
    fi
  done

  if [[ "${ok_all}" == "true" ]]; then
    ok "Precondition checks passed"
    config_save_health_snapshot true "Minimal preflight OK"
  else
    err "Missing required commands: ${missing[*]}"
    config_save_health_snapshot false "Missing: ${missing[*]}"
  fi
}

preflight_run() {
  header
  info "Loading config: ${CONFIG_FILE}"
  config_load
  init_colors

  info "Running minimal preflight..."
  preflight_minimal

  if [[ -x "${HEALTH_SCRIPT}" ]]; then
    info "Delegating extended health check to: ${HEALTH_SCRIPT}"
    # The sub-script will be implemented next. It should return 0/1 and update config via jq.
    "${HEALTH_SCRIPT}" --preflight --config "${CONFIG_FILE}" --script-dir "${SCRIPT_DIR}" || true
    # reload health snapshot after sub-script
    config_load
    init_colors
  else
    warn "Health sub-script not found yet: ${HEALTH_SCRIPT}"
  fi

  pause_enter
}

# ------------------------- systemd (native) -----------------------------------
list_native_loaded_units() {
  systemctl list-units --type=service --all "${SYSTEMD_UNIT_GLOB}" --no-legend --no-pager 2>/dev/null \
    | awk '{print $1}' | sed '/^$/d' || true
}

unit_state() { systemctl is-active "$1" 2>/dev/null || echo "unknown"; }

unit_execstart() { systemctl show -p ExecStart --value "$1" 2>/dev/null || true; }

parse_execstart_mb() {
  local ex="$1"
  local m b
  m="$(sed -nE 's/.*(^|[[:space:]])-m[[:space:]]+([0-9]+).*/\2/p' <<<"$ex" | head -n1)"
  b="$(sed -nE 's/.*(^|[[:space:]])-b[[:space:]]+(-1|[0-9]+(\.[0-9]+)?).*/\2/p' <<<"$ex" | head -n1)"
  [[ -z "$m" ]] && m="-"
  [[ -z "$b" ]] && b="-"
  echo "${m}|${b}"
}

bw_pretty() { [[ "$1" == "-1" ]] && echo "∞" || echo "$1"; }

last_stats_native() {
  journalctl -u "$1" -n 200 --no-pager -o cat 2>/dev/null | grep -F "[STATS]" | tail -n1 || true
}

create_native_unit_file() {
  local unit="$1" max_clients="$2" bandwidth="$3" datadir="$4" statsfile="$5"

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

native_single_action() {
  need_root || return 0
  local -a units
  mapfile -t units < <(list_native_loaded_units)
  local unit
  unit="$(pick_from_list "Pick native unit" "${units[@]}")"
  [[ -z "${unit}" ]] && return 0

  local action
  action="$(pick_from_list "Action for ${unit}" "start" "stop" "restart" "enable" "disable" "status")"
  [[ -z "${action}" ]] && return 0

  case "$action" in
    start)   systemctl daemon-reload >/dev/null 2>&1 || true; systemctl start "$unit" ;;
    stop)    systemctl daemon-reload >/dev/null 2>&1 || true; systemctl stop "$unit" ;;
    restart) systemctl daemon-reload >/dev/null 2>&1 || true; systemctl restart "$unit" ;;
    enable)  systemctl daemon-reload >/dev/null 2>&1 || true; systemctl enable "$unit" ;;
    disable) systemctl daemon-reload >/dev/null 2>&1 || true; systemctl disable "$unit" ;;
    status)  systemctl status "$unit" --no-pager ;;
  esac

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

  header
  warn "This will STOP first, then DISABLE and REMOVE:"
  printf "  - %s\n  - %s\n\n" "${UNIT_DIR}/${unit}" "${datadir}"
  local confirm
  read -r -p "Type DELETE to confirm: " confirm </dev/tty || true
  [[ "${confirm:-}" != "DELETE" ]] && { ok "Canceled."; pause_enter; return 0; }

  systemctl stop "${unit}" >/dev/null 2>&1 || true
  systemctl disable "${unit}" >/dev/null 2>&1 || true
  rm -rf "${datadir}" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  ok "Deleted ${unit}"
  pause_enter
}

native_view_logs_last10() {
  local -a units
  mapfile -t units < <(list_native_loaded_units)
  local unit
  unit="$(pick_from_list "Pick native unit (journalctl last 10)" "${units[@]}")"
  [[ -z "${unit}" ]] && return 0

  header
  printf "%sLast 10 log lines:%s %s\n\n" "${C_BOLD}" "${C_RESET}" "${unit}"
  journalctl -u "${unit}" -n "${CFG_LOG_TAIL}" --no-pager 2>/dev/null || true
  pause_enter
}

# ------------------------- Docker (NO docker-compose) ---------------------------
docker_available() { has docker && docker info >/dev/null 2>&1; }

list_docker_conduits() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i '^conduit' || true
}

docker_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "unknown"
}

last_stats_docker() {
  docker logs --tail 200 "$1" 2>/dev/null | grep -F "[STATS]" | tail -n1 || true
}


docker_list_conduit_containers() {
  # List containers from Docker (source of truth). Show both new naming and legacy ones.
  docker ps -a --format '{{.Names}}' 2>/dev/null \
    | grep -E '^(Conduit[0-9]+\.docker|conduit[0-9]+|conduit)$' || true
}


docker_instance_conf_path() {
  local inst="$1"
  echo "${DOCKER_INSTANCES_DIR}/${inst}/instance.conf"
}

docker_load_instance_conf() {
  # shellcheck disable=SC1090
  local conf="$1"
  [[ -f "$conf" ]] || return 1
  CONTAINER_NAME=""; VOLUME_NAME=""; NETWORK_MODE=""; PORT_ARGS=""; RUN_CMD=""; DATA_MOUNT=""
  source "$conf"
  return 0
}

docker_write_instance_conf() {
  local conf="$1"
  cat > "$conf" <<EOF
# Conduit Docker instance configuration
# This file is sourced by the manager. Keep it simple and safe.
CONTAINER_NAME="${CONTAINER_NAME}"
VOLUME_NAME="${VOLUME_NAME}"
NETWORK_MODE="${NETWORK_MODE}"   # host OR bridge
PORT_ARGS="${PORT_ARGS}"         # e.g., -p 8080:8080 (only used for bridge)
DATA_MOUNT="${DATA_MOUNT}"       # e.g., /data
RUN_CMD="${RUN_CMD}"             # command executed inside container
EOF
}

docker_get_m_b_from_conf() {
  local inst="$1"
  local conf
  conf="$(docker_instance_conf_path "$inst")"
  docker_load_instance_conf "$conf" || { echo "- -"; return 0; }

  local m="-" b="-"
  if [[ "${RUN_CMD:-}" =~ ([-][m][[:space:]]+)([^[:space:]]+) ]]; then
    m="${BASH_REMATCH[2]}"
  elif [[ "${RUN_CMD:-}" =~ (--max-clients[[:space:]]+)([^[:space:]]+) ]]; then
    m="${BASH_REMATCH[2]}"
  fi

  if [[ "${RUN_CMD:-}" =~ ([-][b][[:space:]]+)([^[:space:]]+) ]]; then
    b="${BASH_REMATCH[2]}"
  elif [[ "${RUN_CMD:-}" =~ (--bandwidth[[:space:]]+)([^[:space:]]+) ]]; then
    b="${BASH_REMATCH[2]}"
  fi

  echo "$m" "$b"
}


docker_pull_latest() {
  need_root || return 1
  docker_available || { err "Docker not available."; return 1; }
  ok "Pulling image: ${DOCKER_IMAGE}"
  docker pull "${DOCKER_IMAGE}" >/dev/null 2>&1 || { err "docker pull failed: ${DOCKER_IMAGE}"; return 1; }
  return 0
}

docker_run_from_conf() {
  local inst="$1"
  local conf
  conf="$(docker_instance_conf_path "$inst")"
  docker_load_instance_conf "$conf" || { err "Missing config: $conf"; return 1; }

  docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || docker volume create "$VOLUME_NAME" >/dev/null 2>&1 || true
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  local -a net_args=()
  if [[ "${NETWORK_MODE}" == "host" ]]; then
    net_args+=(--network host)
  else
    # shellcheck disable=SC2206
    net_args+=(${PORT_ARGS})
  fi

  local out rc
  out="$(docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    "${net_args[@]}" \
    -v "$VOLUME_NAME":"$DATA_MOUNT" \
    "$DOCKER_IMAGE" /bin/sh -lc "$RUN_CMD" 2>&1)"; rc=$?

  if (( rc == 0 )); then
    ok "Container started: $CONTAINER_NAME"
  else
    err "docker run failed (rc=${rc})."
    printf "%s\n" "$out"
    return $rc
  fi
  return 0
}

docker_update_all_instances() {
  need_root || return 1
  docker_available || { err "Docker not available."; return 1; }
  mkdir -p "${DOCKER_INSTANCES_DIR}" >/dev/null 2>&1 || true

  docker_pull_latest || return 1

  local any=0
  local inst
  for inst in "${DOCKER_INSTANCES_DIR}"/conduit*; do
    [[ -d "$inst" ]] || continue
    [[ -f "$inst/instance.conf" ]] || continue
    any=1
    local name
    name="$(basename "$inst")"
    ok "Updating docker instance: $name"
    docker_run_from_conf "$name" >/dev/null 2>&1 || true
  done

  (( any == 0 )) && warn "No docker instances found under ${DOCKER_INSTANCES_DIR}."
  return 0
}


_docker_start_instance() {
  local inst="$1"
  docker_pull_latest || return 1
  docker_run_from_conf "$inst"
}

_docker_stop_instance() {
  local inst="$1"
  local conf
  conf="$(docker_instance_conf_path "$inst")"
  docker_load_instance_conf "$conf" || return 1
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  return 0
}

docker_create_instance() {
  need_root || return 0
  docker_available || { err "Docker not available."; pause_enter; return 0; }

  header
  printf "%sCreate New Docker Instance%s

" "${C_BOLD}" "${C_RESET}"
  echo "Naming convention: ConduitXXX.docker"
  echo "A new dedicated Docker volume + a new local folder will be created for every instance."
  echo

  read -r -p "Instance number (e.g., 250) : " num </dev/tty || true
  [[ -z "${num}" ]] && return 0
  [[ "${num}" =~ ^[0-9]+$ ]] || { warn "Invalid number"; pause_enter; return 0; }

  local inst_id="conduit${num}"
  local cname="Conduit${num}.docker"
  local inst_dir="${DOCKER_INSTANCES_DIR}/${inst_id}"
  local conf="${inst_dir}/instance.conf"

  if docker ps -a --format '{{.Names}}' | grep -Fxq "${cname}"; then
    err "A container with this name already exists: ${cname}"
    pause_enter
    return 0
  fi

  if [[ -d "${inst_dir}" ]]; then
    warn "Instance folder already exists: ${inst_dir}"
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

  mkdir -p "${inst_dir}" >/dev/null 2>&1 || true

  local volume="conduit${num}-data"
  local data_mount="/home/conduit/data"
  local run_cmd="conduit start -m ${m} -b ${bw} -d ${data_mount} --stats-file ${data_mount}/stats.json"

  # Persist our manager-side config (secondary source of truth).
  CONTAINER_NAME="${cname}"
  VOLUME_NAME="${volume}"
  NETWORK_MODE="host"
  PORT_ARGS=""
  DATA_MOUNT="${data_mount}"
  RUN_CMD="${run_cmd}"
  docker_write_instance_conf "${conf}"

  info "Creating Docker volume: ${volume}"
  docker volume create "${volume}"

  info "Pulling image: ${DOCKER_IMAGE}"
  docker pull "${DOCKER_IMAGE}"

  info "Starting container: ${cname}"
  docker run -d --name "${cname}" \
    -v "${volume}:${data_mount}" \
    --restart unless-stopped \
    "${DOCKER_IMAGE}" \
    ${run_cmd}

  ok "Created Docker instance: ${cname}"
  pause_enter
}

docker_single_action() {
  need_root || return 0
  docker_available || { err "Docker not available."; pause_enter; return 0; }

  local -a names=()
  mapfile -t names < <(docker_list_conduit_containers)

  local cname
  cname="$(pick_from_list "Pick docker container (read from Docker)" "${names[@]}")"
  [[ -z "${cname}" ]] && return 0

  local action
  action="$(pick_from_list "Action for ${cname}" "start" "stop" "restart" "status")"
  [[ -z "${action}" ]] && return 0

  header
  printf "%sDocker: %s%s

" "${C_BOLD}" "${cname}" "${C_RESET}"

  case "${action}" in
    start)
      docker start "${cname}"
      ;;
    stop)
      docker stop "${cname}"
      ;;
    restart)
      docker restart "${cname}"
      ;;
    status)
      docker ps -a --filter "name=^${cname}$" --format "table {{.Names}}	{{.Status}}	{{.Image}}" | sed 's/	/  /g'
      ;;
  esac

  echo
  echo "Detected runtime settings (best-effort):"
  local mb; mb="$(docker_get_m_b "${cname}")"
  echo "  -m: ${mb%%|*}"
  echo "  -b: ${mb##*|}"

  pause_enter
}

docker_delete_instance() {
  need_root || return 0
  docker_available || { err "Docker not available."; pause_enter; return 0; }

  local -a names=()
  mapfile -t names < <(docker_list_conduit_containers)
  local cname
  cname="$(pick_from_list "Pick docker container to DELETE" "${names[@]}")"
  [[ -z "${cname}" ]] && return 0

  # Try to find our manager conf by container name (if this was created by this tool).
  local conf=""
  conf="$(docker_find_conf_by_container "${cname}" 2>/dev/null || true)"

  local volume=""
  local inst_dir=""
  if [[ -n "${conf}" && -f "${conf}" ]]; then
    docker_load_instance_conf "${conf}" || true
    volume="${VOLUME_NAME:-}"
    inst_dir="$(dirname "${conf}")"
  fi

  header
  printf "%sDELETE Docker container%s

" "${C_BOLD}" "${C_RESET}"
  echo "Container: ${cname}"
  [[ -n "${volume}" ]] && echo "Volume:    ${volume}"
  [[ -n "${inst_dir}" ]] && echo "Folder:    ${inst_dir}"
  echo
  read -r -p "Type DELETE to confirm: " confirm </dev/tty || true
  [[ "${confirm}" != "DELETE" ]] && { warn "Cancelled."; pause_enter; return 0; }

  info "Stopping container (if running)..."
  docker stop "${cname}" 2>&1 || true

  info "Removing container..."
  docker rm "${cname}" 2>&1 || true

  if [[ -n "${volume}" ]]; then
    info "Removing volume: ${volume}"
    docker volume rm "${volume}" 2>&1 || true
  else
    warn "Volume name not found in manager config; skipping volume deletion."
  fi

  if [[ -n "${inst_dir}" && -d "${inst_dir}" ]]; then
    info "Removing folder: ${inst_dir}"
    rm -rf "${inst_dir}" 2>&1 || true
  fi

  ok "Deleted docker container: ${cname}"
  pause_enter
}

docker_logs_last10() {
  need_root || return 0
  docker_available || { err "Docker not available."; pause_enter; return 0; }

  local -a names=()
  mapfile -t names < <(docker_list_conduit_containers)
  local cname
  cname="$(pick_from_list "Pick docker container for logs" "${names[@]}")"
  [[ -z "${cname}" ]] && return 0

  header
  printf "%sLast %d docker log lines: %s%s

" "${C_BOLD}" "${CFG_LOG_TAIL}" "${cname}" "${C_RESET}"
  docker logs --tail "${CFG_LOG_TAIL}" "${cname}" 2>&1 || true
  pause_enter
}

# ------------------------- Install/Update native conduit binary ----------------
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
  has curl || { err "curl is required."; pause_enter; return 0; }

  local asset
  asset="$(arch_asset)"
  [[ -z "$asset" ]] && { err "Unsupported arch: $(uname -m)"; pause_enter; return 0; }

  local url="https://github.com/${CONDUIT_REPO}/releases/latest/download/${asset}"

  header
  printf "%sInstall/Update Native conduit binary%s\n\n" "${C_BOLD}" "${C_RESET}"
  printf "Target: %s\nSource: %s\n\n" "${NATIVE_BIN}" "${url}"

  mkdir -p "${INSTALL_DIR}" >/dev/null 2>&1 || true

  local tmp
  tmp="$(mktemp -t conduit.XXXXXX)"
  if ! curl -fsSL -o "${tmp}" "${url}"; then
    err "Download failed."
    rm -f "${tmp}" >/dev/null 2>&1 || true
    pause_enter
    return 0
  fi

  chmod +x "${tmp}" >/dev/null 2>&1 || true

  if has file; then
    if ! file "${tmp}" | grep -qi 'ELF'; then
      err "Downloaded file doesn't look like a Linux ELF binary."
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

# ------------------------- Network throughput (Mbps) ----------------------------
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

iface_exists() { [[ -d "/sys/class/net/$1" ]]; }

default_iface() {
  local ifc="${CFG_NET_IFACE}"
  iface_exists "$ifc" && { echo "$ifc"; return; }
  iface_exists "${NET_IFACE_DEFAULT}" && { echo "${NET_IFACE_DEFAULT}"; return; }
  ls -1 /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n1
}

# ------------------------- Stats parsing/formatting -----------------------------
human_to_bytes() {
  local s
  s="$(trim "${1:-0B}")"
  s="$(sed -E 's/([0-9]) +([A-Za-z])/\1\2/g' <<<"$s")"
  local num unit
  num="$(sed -E 's/^([0-9]+(\.[0-9]+)?).*/\1/' <<<"$s")"
  unit="$(sed -E 's/^[0-9]+(\.[0-9]+)?([A-Za-z]+).*/\2/' <<<"$s")"
  [[ -z "$num" ]] && num="0"
  [[ -z "$unit" ]] && unit="B"
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

bytes_to_human_nospace() {
  local b="${1:-0}"
  [[ -z "$b" ]] && b=0
  if (( b < 1024 )); then echo "${b}B"; return; fi
  if (( b < 1024*1024 )); then awk "BEGIN{printf \"%.1fKB\", $b/1024}"; return; fi
  if (( b < 1024*1024*1024 )); then awk "BEGIN{printf \"%.1fMB\", $b/1024/1024}"; return; fi
  if (( b < 1024*1024*1024*1024 )); then awk "BEGIN{printf \"%.1fGB\", $b/1024/1024/1024}"; return; fi
  awk "BEGIN{printf \"%.1fTB\", $b/1024/1024/1024/1024}"
}

parse_stats_line() {
  local line="${1:-}"
  local connecting connected up down uptime
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

# ------------------------- Dashboard rendering (aligned) ------------------------
print_nic_box() {
  local iface="$1" rx="$2" tx="$3"
  printf "%s┌──────────────────────────────────────────────┐%s\n" "${C_CYAN}" "${C_RESET}"
  printf "%s│%s 📡 NIC: %-10s %sRX:%s %8s Mbps  %sTX:%s %8s Mbps %s│%s\n" \
    "${C_CYAN}" "${C_RESET}" "$iface" \
    "${C_DIM}" "${C_RESET}" "$rx" "${C_DIM}" "${C_RESET}" "$tx" \
    "${C_CYAN}" "${C_RESET}"
  printf "%s└──────────────────────────────────────────────┘%s\n\n" "${C_CYAN}" "${C_RESET}"
}

print_dash_header() {
  printf "%-6s %-24s %3s %11s %10s %10s %10s %11s %5s %5s\n" \
    "TYPE" "NAME" "ST" "Connecting" "Connected" "Up" "Down" "Uptime" "-m" "-b"
  printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────"
}

print_dash_row() {
  local type="$1" name="$2" st="$3" connecting="$4" connected="$5" up="$6" down="$7" uptime="$8" m="$9" b="${10}"
  printf "%-6s %-24.24s %3s %11s %10s %10s %10s %11s %5s %5s\n" \
    "$type" "$name" "$st" "$connecting" "$connected" "$up" "$down" "$uptime" "$m" "$b"
}

print_totals_box() {
  local services="$1" okc="$2" waitc="$3" errc="$4" tconn="$5" tconnected="$6" tup="$7" tdown="$8"
  printf "\n%s┌────────────────────────────────────────────────────────────────────────────┐%s\n" "${C_CYAN}" "${C_RESET}"
  printf "%s│%s 📊 TOTAL: Services=%s | ✅ OK=%s | ⏳ WAIT=%s | 🔴 ERR/DOWN=%s%*s%s│%s\n" \
    "${C_CYAN}" "${C_RESET}" "$services" "$okc" "$waitc" "$errc" 1 "" "${C_CYAN}" "${C_RESET}"
  printf "%s│%s 🔌 Connecting=%s | 🟢 Connected=%s | ⬆️ Up=%s | ⬇️ Down=%s%*s%s│%s\n" \
    "${C_CYAN}" "${C_RESET}" "$tconn" "$tconnected" "$tup" "$tdown" 1 "" "${C_CYAN}" "${C_RESET}"
  printf "%s└────────────────────────────────────────────────────────────────────────────┘%s\n" "${C_CYAN}" "${C_RESET}"
}

print_legend_end() {
  printf "\nLegend: %s●%s (system error / down)   %s●%s (waiting for stats)   %s●%s (connected & active)\n" \
    "${C_RED}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}" "${C_GREEN}" "${C_RESET}"
}

status_dot() {
  local state="$1" upb="$2" downb="$3"
  if [[ "$state" != "active" && "$state" != "running" && "$state" != "exited" ]]; then
    printf "%s●%s" "${C_RED}" "${C_RESET}"
    return
  fi
  if (( upb > 0 || downb > 0 )); then
    printf "%s●%s" "${C_GREEN}" "${C_RESET}"
  else
    printf "%s●%s" "${C_YELLOW}" "${C_RESET}"
  fi
}

dashboard() {
  local ifc
  ifc="$(default_iface)"

  local prev now prev_rx prev_tx now_rx now_tx
  prev="$(read_iface_bytes "$ifc")"
  prev_rx="${prev%%|*}"
  prev_tx="${prev##*|}"
  sleep 1
  now="$(read_iface_bytes "$ifc")"
  now_rx="${now%%|*}"
  now_tx="${now##*|}"

  local rx_mbps tx_mbps
  rx_mbps="$(awk "BEGIN{printf \"%.2f\", (${now_rx}-${prev_rx})*8/1000000}")"
  tx_mbps="$(awk "BEGIN{printf \"%.2f\", (${now_tx}-${prev_tx})*8/1000000}")"

  header
  printf "%sLive Dashboard%s  (refresh=%ss, iface=%s)\n\n" "${C_BOLD}" "${C_RESET}" "${CFG_REFRESH_SECS}" "${ifc}"
  print_nic_box "$ifc" "$rx_mbps" "$tx_mbps"

  print_dash_header

  local total_services=0 okc=0 waitc=0 errc=0
  local tconn=0 tconnected=0 tupb=0 tdownb=0

  # Native rows
  local -a units
  mapfile -t units < <(list_native_loaded_units)
  local u
  for u in "${units[@]}"; do
    [[ -z "$u" ]] && continue
    total_services=$((total_services+1))

    local st exec mb m b stats parsed connecting connected up down uptime
    st="$(unit_state "$u")"
    exec="$(unit_execstart "$u")"
    mb="$(parse_execstart_mb "$exec")"
    m="${mb%%|*}"
    b="$(bw_pretty "${mb##*|}")"

    stats="$(last_stats_native "$u")"
    if [[ -n "$stats" ]]; then
      parsed="$(parse_stats_line "$stats")"
      connecting="${parsed%%|*}"; parsed="${parsed#*|}"
      connected="${parsed%%|*}"; parsed="${parsed#*|}"
      up="${parsed%%|*}"; parsed="${parsed#*|}"
      down="${parsed%%|*}"; uptime="${parsed##*|}"
    else
      connecting="-"; connected="-"; up="0B"; down="0B"; uptime="-"
    fi

    local upb downb dot
    upb="$(human_to_bytes "$up" 2>/dev/null || echo 0)"
    downb="$(human_to_bytes "$down" 2>/dev/null || echo 0)"
    dot="$(status_dot "$st" "$upb" "$downb")"

    # totals
    if [[ "$st" != "active" ]]; then
      errc=$((errc+1))
    else
      if (( upb > 0 || downb > 0 )); then okc=$((okc+1)); else waitc=$((waitc+1)); fi
    fi

    [[ "$connecting" =~ ^[0-9]+$ ]] && tconn=$((tconn+connecting))
    [[ "$connected" =~ ^[0-9]+$ ]] && tconnected=$((tconnected+connected))
    tupb=$((tupb+upb))
    tdownb=$((tdownb+downb))

    print_dash_row "native" "$u" "$dot" "$connecting" "$connected" "$up" "$down" "$uptime" "$m" "$b"
  done

  # Docker rows (managed instances if any; otherwise raw containers)
  local managed_any=0
  local d
  if [[ -d "${DOCKER_INSTANCES_DIR}" ]]; then
    for d in "${DOCKER_INSTANCES_DIR}"/conduit*; do
      [[ -d "$d" && -f "$d/instance.conf" ]] || continue
      managed_any=1
      local inst
      inst="$(basename "$d")"
      total_services=$((total_services+1))

      local st stats parsed connecting connected up down uptime m b
      st="$(docker_state "$inst")"

      stats="$(last_stats_docker "$inst")"
      if [[ -n "$stats" ]]; then
        parsed="$(parse_stats_line "$stats")"
        connecting="${parsed%%|*}"; parsed="${parsed#*|}"
        connected="${parsed%%|*}"; parsed="${parsed#*|}"
        up="${parsed%%|*}"; parsed="${parsed#*|}"
        down="${parsed%%|*}"; uptime="${parsed##*|}"
      else
        connecting="-"; connected="-"; up="0B"; down="0B"; uptime="-"
      fi

      read -r m b < <(docker_get_m_b_from_conf "$inst")
      b="$(bw_pretty "$b")"

      local upb downb dot
      upb="$(human_to_bytes "$up" 2>/dev/null || echo 0)"
      downb="$(human_to_bytes "$down" 2>/dev/null || echo 0)"
      dot="$(status_dot "$st" "$upb" "$downb")"

      if [[ "$st" != "running" ]]; then
        errc=$((errc+1))
      else
        if (( upb > 0 || downb > 0 )); then okc=$((okc+1)); else waitc=$((waitc+1)); fi
      fi

      [[ "$connecting" =~ ^[0-9]+$ ]] && tconn=$((tconn+connecting))
      [[ "$connected" =~ ^[0-9]+$ ]] && tconnected=$((tconnected+connected))
      tupb=$((tupb+upb))
      tdownb=$((tdownb+downb))

      print_dash_row "docker" "${inst}" "$dot" "$connecting" "$connected" "$up" "$down" "$uptime" "$m" "$b"
    done
  fi

  if (( managed_any == 0 )); then
    # raw containers
    local -a cs
    mapfile -t cs < <(list_docker_conduits)
    local c
    for c in "${cs[@]}"; do
      [[ -z "$c" ]] && continue
      total_services=$((total_services+1))
      local st stats parsed connecting connected up down uptime
      st="$(docker_state "$c")"
      stats="$(last_stats_docker "$c")"
      if [[ -n "$stats" ]]; then
        parsed="$(parse_stats_line "$stats")"
        connecting="${parsed%%|*}"; parsed="${parsed#*|}"
        connected="${parsed%%|*}"; parsed="${parsed#*|}"
        up="${parsed%%|*}"; parsed="${parsed#*|}"
        down="${parsed%%|*}"; uptime="${parsed##*|}"
      else
        connecting="-"; connected="-"; up="0B"; down="0B"; uptime="-"
      fi

      local upb downb dot
      upb="$(human_to_bytes "$up" 2>/dev/null || echo 0)"
      downb="$(human_to_bytes "$down" 2>/dev/null || echo 0)"
      dot="$(status_dot "$st" "$upb" "$downb")"

      if [[ "$st" != "running" ]]; then
        errc=$((errc+1))
      else
        if (( upb > 0 || downb > 0 )); then okc=$((okc+1)); else waitc=$((waitc+1)); fi
      fi

      [[ "$connecting" =~ ^[0-9]+$ ]] && tconn=$((tconn+connecting))
      [[ "$connected" =~ ^[0-9]+$ ]] && tconnected=$((tconnected+connected))
      tupb=$((tupb+upb))
      tdownb=$((tdownb+downb))

      print_dash_row "docker" "$c" "$dot" "$connecting" "$connected" "$up" "$down" "$uptime" "-" "-"
    done
  fi

  local tup tdown
  tup="$(bytes_to_human_nospace "$tupb")"
  tdown="$(bytes_to_human_nospace "$tdownb")"

  print_totals_box "$total_services" "$okc" "$waitc" "$errc" "$tconn" "$tconnected" "$tup" "$tdown"
  print_legend_end

  printf "\nPress ENTER or 0 to return. Auto-refresh continues...\n"
  local input=""
  local end_time=$((SECONDS + CFG_REFRESH_SECS))
  while (( SECONDS < end_time )); do
    read -r -t 0.2 input </dev/tty || true
    [[ "${input}" == "0" ]] && return 0
    [[ -n "${input}" ]] && return 0
  done
}

dashboard_loop() {
  while true; do
    dashboard
    return 0
  done
}

# ------------------------- Settings Menu ---------------------------------------
settings_network_menu() {
  while true; do
    header
    printf "%sSettings → Network%s\n\n" "${C_BOLD}" "${C_RESET}"
    printf "Current iface: %s\n\n" "${CFG_NET_IFACE}"
    echo "1) Select network interface"
    echo "2) Quick network check (ping/DNS/curl) [delegated to Health script]"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1)
        local -a ifs
        mapfile -t ifs < <(ls -1 /sys/class/net 2>/dev/null | sed '/^$/d' || true)
        local picked
        picked="$(pick_from_list "Pick network interface" "${ifs[@]}")"
        [[ -z "$picked" ]] && continue
        CFG_NET_IFACE="$picked"
        config_save_network_iface "$picked" || true
        config_load; init_colors
        ;;
      2)
        if [[ -x "${HEALTH_SCRIPT}" ]]; then
          "${HEALTH_SCRIPT}" --network-check --config "${CONFIG_FILE}" --script-dir "${SCRIPT_DIR}" || true
          config_load; init_colors
        else
          warn "Health script not found yet: ${HEALTH_SCRIPT}"
          pause_enter
        fi
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

settings_console_menu() {
  while true; do
    header
    printf "%sSettings → Console%s\n\n" "${C_BOLD}" "${C_RESET}"
    printf "Refresh seconds: %s\n" "${CFG_REFRESH_SECS}"
    printf "Log tail lines : %s\n" "${CFG_LOG_TAIL}"
    printf "Color output   : %s\n\n" "${CFG_COLOR}"

    echo "1) Set refresh seconds"
    echo "2) Set log tail lines"
    echo "3) Toggle colors"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1)
        local v
        read -r -p "New refresh seconds (1..300): " v </dev/tty || true
        [[ "${v:-}" =~ ^[0-9]+$ ]] || { warn "Invalid number"; pause_enter; continue; }
        (( v >= 1 && v <= 300 )) || { warn "Out of range"; pause_enter; continue; }
        CFG_REFRESH_SECS="$v"
        config_save_console_refresh "$v" || true
        config_load; init_colors
        ;;
      2)
        local v
        read -r -p "New log tail lines (1..200): " v </dev/tty || true
        [[ "${v:-}" =~ ^[0-9]+$ ]] || { warn "Invalid number"; pause_enter; continue; }
        (( v >= 1 && v <= 200 )) || { warn "Out of range"; pause_enter; continue; }
        CFG_LOG_TAIL="$v"
        config_save_console_logtail "$v" || true
        config_load; init_colors
        ;;
      3)
        if [[ "${CFG_COLOR}" == "true" ]]; then
          CFG_COLOR="false"
          config_save_console_color false || true
        else
          CFG_COLOR="true"
          config_save_console_color true || true
        fi
        config_load; init_colors
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

settings_health_menu() {
  while true; do
    header
    printf "%sSettings → Health Status%s\n\n" "${C_BOLD}" "${C_RESET}"
    printf "Last run : %s\n" "${CFG_HEALTH_LAST_RUN:-}"
    printf "OK       : %s\n" "${CFG_HEALTH_OK:-false}"
    printf "Summary  : %s\n\n" "${CFG_HEALTH_SUMMARY:-}"

    echo "1) Run extended health check (delegated)"
    echo "2) Install dependencies (one by one) (delegated)"
    echo "3) Show docker status"
    echo "4) Show native binary status"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1)
        if [[ -x "${HEALTH_SCRIPT}" ]]; then
          "${HEALTH_SCRIPT}" --run --config "${CONFIG_FILE}" --script-dir "${SCRIPT_DIR}" || true
          config_load; init_colors
        else
          warn "Health script not found yet: ${HEALTH_SCRIPT}"
          pause_enter
        fi
        ;;
      2)
        if [[ -x "${HEALTH_SCRIPT}" ]]; then
          "${HEALTH_SCRIPT}" --install --config "${CONFIG_FILE}" --script-dir "${SCRIPT_DIR}" || true
          config_load; init_colors
        else
          warn "Health script not found yet: ${HEALTH_SCRIPT}"
          pause_enter
        fi
        ;;
      3)
        header
        if docker_available; then
          ok "Docker is available."
          docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | sed 's/\t/  /g'
        else
          err "Docker is not available or daemon not running."
        fi
        pause_enter
        ;;
      4)
        header
        if [[ -x "${NATIVE_BIN}" ]]; then
          ok "Native conduit is installed: ${NATIVE_BIN}"
          "${NATIVE_BIN}" --version 2>/dev/null || true
        else
          err "Native conduit not found: ${NATIVE_BIN}"
        fi
        pause_enter
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

menu_settings() {
  while true; do
    header
    printf "%sSettings%s\n\n" "${C_BOLD}" "${C_RESET}"
    echo "1) Network settings"
    echo "2) Console settings"
    echo "3) Health status"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) settings_network_menu ;;
      2) settings_console_menu ;;
      3) settings_health_menu ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

# ------------------------- Main Menus ------------------------------------------
menu_native() {
  while true; do
    header
    printf "%sNative (systemd) Menu%s\n\n" "${C_BOLD}" "${C_RESET}"
    echo "1) Create native instance (conduit<NUM>.service)"
    echo "2) Start/Stop/Restart/Enable/Disable (single)"
    echo "3) Delete native instance (FULL remove)"
    echo "4) Show last 10 native log lines (journalctl)"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) native_create_instance ;;
      2) native_single_action ;;
      3) native_delete_instance ;;
      4) native_view_logs_last10 ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

menu_docker() {
  while true; do
    header
    printf "%sDocker Menu%s\n\n" "${C_BOLD}" "${C_RESET}"
    echo "1) Create docker instance (docker run + volume + local config)"
    echo "2) Start/Stop/Restart (single instance)"
    echo "3) Delete docker instance (container + volume + dir)"
    echo "4) Show last 10 docker log lines"
    echo "5) Update all docker instances (docker pull :latest + recreate)"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) docker_create_instance ;;
      2) docker_single_action ;;
      3) docker_delete_instance ;;
      4) docker_logs_last10 ;;
      5) need_root && docker_update_all_instances && pause_enter ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

main_menu() {
  while true; do
    header
    printf "%sMain Menu%s\n\n" "${C_BOLD}" "${C_RESET}"
    echo "1) Live Dashboard (Native + Docker + Totals)"
    echo "2) Native (systemd) management"
    echo "3) Docker management"
    echo "4) Install/Update Native conduit (latest)"
    echo "5) Settings"
    echo "6) Run preflight (minimal + delegated)"
    echo "0) Exit"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) dashboard_loop ;;
      2) menu_native ;;
      3) menu_docker ;;
      4) install_update_native ;;
      5) menu_settings ;;
      6) preflight_run ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}


# ------------------------- Start ------------------------------------------------
config_load
init_colors

# Run minimal preflight once on startup (non-blocking; detailed is delegated)
preflight_minimal

main_menu
