#!/usr/bin/env bash
# ==============================================================================
# Conduit Console Manager (Native + Docker) - Main Console
# ------------------------------------------------------------------------------
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (C) 2026 Babak Sorkhpour
# Written by Dr. Babak Sorkhpour with help of ChatGPT
#
# Version: 0.3.4
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
APP_VER="0.3.5"

# ------------------------- Paths (console-local) -------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"

# Optional project branding (per project guidelines)
PROJECT_CONF="${SCRIPT_DIR}/project.conf"
# Defaults (project.conf may override)
PROJECT_NAME="${PROJECT_NAME:-Conduit Console Manager}"
REPO_URL="${REPO_URL:-https://github.com/babakskr/Conduit-console.git}"
AUTHOR_NAME="${AUTHOR_NAME:-Babak Sorkhpour}"
if [[ -f "${PROJECT_CONF}" ]]; then
  # shellcheck source=/dev/null
  source "${PROJECT_CONF}"
fi

# Use branded project name in UI
APP_NAME="${PROJECT_NAME}"

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
CFG_VIEW_DEFAULT="ALL"
CFG_COMPACT_DEFAULT="0"
CFG_STATS_TTL="15"
CFG_MAX_LOG_JOBS="4"
CFG_FILE_DEFAULT="/etc/conduit-console/conduit-console.conf"
CFG_FILE="$CFG_FILE_DEFAULT"
CFG_MTIME=0
# Theme defaults (names: black,red,green,yellow,blue,purple,cyan,white or 0..7)
CFG_COLOR_DOCKER="purple"
CFG_COLOR_NATIVE="blue"
CFG_COLOR_TITLE="white"
CFG_COLOR_HEADER="cyan"
CFG_COLOR_LEGEND_ACTIVE="green"
CFG_COLOR_LEGEND_IDLE="yellow"
CFG_COLOR_LEGEND_DOWN="red"
CFG_COLOR_NIC_LABEL="cyan"
CFG_COLOR_NIC_RX="green"
CFG_COLOR_NIC_TX="red"


# Optimizer defaults (stored in config when jq exists)
OPT_TARGET_KEYWORD_DEFAULT="conduit"
OPT_DOCKER_PRI_DEFAULT=10   # 5..20, lower is higher priority (mapped to nice)
OPT_NATIVE_PRI_DEFAULT=15   # 5..20
OPT_VERBOSE_DEFAULT="false"

CFG_OPT_TARGET_KEYWORD="${OPT_TARGET_KEYWORD_DEFAULT}"
CFG_OPT_DOCKER_PRI="${OPT_DOCKER_PRI_DEFAULT}"
CFG_OPT_NATIVE_PRI="${OPT_NATIVE_PRI_DEFAULT}"
CFG_OPT_VERBOSE="${OPT_VERBOSE_DEFAULT}"

# Console UI width cap (max columns to render). Controlled by CLI -b and/or env CONDUIT_CONSOLE_COLS.
UI_MAX_COLS_DEFAULT=104
UI_MAX_COLS="${CONDUIT_CONSOLE_COLS:-$UI_MAX_COLS_DEFAULT}"

# Persisted width cap (stored in config as CONSOLE_COLS)
CFG_CONSOLE_COLS="${UI_MAX_COLS}"

# Snapshot concurrency (max background collectors per refresh)
CFG_MAX_JOBS_DEFAULT=12
CFG_MAX_JOBS="${CONDUIT_CONSOLE_MAX_JOBS:-$CFG_MAX_JOBS_DEFAULT}"

show_help() {
  cat <<'EOF'
Description:
  Conduit-console interactive TUI manager for Native (systemd) and Docker Conduit instances.

Usage:
  conduit-console.sh [options]

Options:
  -h, --help        Show this help.
  -b <cols>         Cap dashboard width to <cols> columns (hard limit).
  -i <iface>        Default network interface for NIC stats (e.g., eth0).
  -r <seconds>      Dashboard refresh interval in seconds.

Examples:
  conduit-console.sh
  conduit-console.sh -b 120 -i eth0 -r 5
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) show_help; exit 0 ;;
      -b) shift; UI_MAX_COLS="${1:-$UI_MAX_COLS}"; CFG_CONSOLE_COLS="$UI_MAX_COLS" ;;
      -i) shift; CFG_NET_IFACE="${1:-$CFG_NET_IFACE}" ;;
      -r) shift; CFG_REFRESH_SECS="${1:-$CFG_REFRESH_SECS}" ;;
      --) shift; break ;;
      *) break ;;
    esac
    shift || true
  done
}

# last health snapshot (stored in config json)
CFG_HEALTH_LAST_RUN=""
CFG_HEALTH_OK="false"
CFG_HEALTH_SUMMARY=""

# ------------------------- UI (colors + helpers) ------------------------------
has() { command -v "$1" >/dev/null 2>&1; }


# ------------------------- Config (KV file) ----------------------------------
cfg_ensure_dir(){ local d; d="$(dirname "$CFG_FILE")"; mkdir -p "$d" >/dev/null 2>&1 || true; }

cfg_load_kv(){ cfg_load_all || true; }

cfg_save_kv(){ cfg_save_all || true; }

cfg_reload_fast() {
  # Fast reload: only re-read config if mtime changed.
  local f="$CFG_FILE" mt="0"
  cfg_write_default || true
  mt="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  if [[ "${CFG_MTIME:-0}" != "$mt" ]]; then
    cfg_load_all || true
    CFG_MTIME="$mt"
  fi
}


color_name_to_code(){
  local n="${1,,}"
  case "$n" in
    black|0) echo 0;; red|1) echo 1;; green|2) echo 2;; yellow|3) echo 3;;
    blue|4) echo 4;; purple|magenta|5) echo 5;; cyan|6) echo 6;; white|7) echo 7;;
    *) echo 7;;
  esac
}

apply_theme_colors(){
  # Defaults map to legacy colors.
  C_ROW_DOCKER="$C_PURPLE"
  C_ROW_NATIVE="$C_BLUE"
  C_TITLE_CLR="$C_WHITE"
  C_HEADER_CLR="$C_CYAN"
  C_LEG_ACTIVE="$C_GREEN"
  C_LEG_IDLE="$C_YELLOW"
  C_LEG_DOWN="$C_RED"
  C_NIC_LBL_CLR="$C_CYAN"
  C_NIC_RX_CLR="$C_GREEN"
  C_NIC_TX_CLR="$C_RED"
  C_BLINK=""
  if [[ "${CFG_COLOR}" == "true" && -t 1 && -t 2 ]] && has tput; then
    C_BLINK="$(tput blink 2>/dev/null || true)"
    [[ -z "$C_BLINK" ]] && C_BLINK=$'\e[5m'
    C_ROW_DOCKER="$(tput setaf "$(color_name_to_code "$CFG_COLOR_DOCKER")" 2>/dev/null || echo "$C_ROW_DOCKER")"
    C_ROW_NATIVE="$(tput setaf "$(color_name_to_code "$CFG_COLOR_NATIVE")" 2>/dev/null || echo "$C_ROW_NATIVE")"
    C_TITLE_CLR="$(tput setaf "$(color_name_to_code "$CFG_COLOR_TITLE")" 2>/dev/null || echo "$C_TITLE_CLR")"
    C_HEADER_CLR="$(tput setaf "$(color_name_to_code "$CFG_COLOR_HEADER")" 2>/dev/null || echo "$C_HEADER_CLR")"
    C_LEG_ACTIVE="$(tput setaf "$(color_name_to_code "$CFG_COLOR_LEGEND_ACTIVE")" 2>/dev/null || echo "$C_LEG_ACTIVE")"
    C_LEG_IDLE="$(tput setaf "$(color_name_to_code "$CFG_COLOR_LEGEND_IDLE")" 2>/dev/null || echo "$C_LEG_IDLE")"
    C_LEG_DOWN="$(tput setaf "$(color_name_to_code "$CFG_COLOR_LEGEND_DOWN")" 2>/dev/null || echo "$C_LEG_DOWN")"
    C_NIC_LBL_CLR="$(tput setaf "$(color_name_to_code "$CFG_COLOR_NIC_LABEL")" 2>/dev/null || echo "$C_NIC_LBL_CLR")"
    C_NIC_RX_CLR="$(tput setaf "$(color_name_to_code "$CFG_COLOR_NIC_RX")" 2>/dev/null || echo "$C_NIC_RX_CLR")"
    C_NIC_TX_CLR="$(tput setaf "$(color_name_to_code "$CFG_COLOR_NIC_TX")" 2>/dev/null || echo "$C_NIC_TX_CLR")"
  fi
}
init_colors() {
  cfg_reload_fast || true
  if [[ "${CFG_COLOR}" == "true" && -t 1 && -t 2 ]] && has tput; then
    C_RESET="$(tput sgr0 || true)"
    C_BOLD="$(tput bold || true)"
    C_DIM="$(tput dim || true)"
    C_RED="$(tput setaf 1 || true)"
    C_GREEN="$(tput setaf 2 || true)"
    C_YELLOW="$(tput setaf 3 || true)"
    C_BLUE="$(tput setaf 4 || true)"
    C_PURPLE="$(tput setaf 5 || true)"
    C_CYAN="$(tput setaf 6 || true)"
    C_WHITE="$(tput setaf 7 || true)"
  else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_PURPLE=""; C_CYAN=""; C_WHITE=""
  fi
  apply_theme_colors

  # Status aliases used by diagnostics tables
  C_OK="${C_GREEN}"
  C_WARN="${C_YELLOW}"
  C_FAIL="${C_RED}"

}

ui_selftest() {
  # A/B sanity tests before interactive UI begins.
  # If ANSI vars are corrupted, hard-disable colors (prevents "0 0tput ..." leaks).
  local bad=0
  for v in C_RESET C_BOLD C_DIM C_RED C_GREEN C_YELLOW C_BLUE C_PURPLE C_CYAN C_WHITE; do
    local val="${!v:-}"
    if [[ "$val" == *"tput"* || "$val" == *"0 0"* || "$val" == *"|| true)"* ]]; then
      bad=1
      break
    fi
  done
  if (( bad )); then
    CFG_COLOR="false"
    init_colors
  fi

  # Formatter A/B: bytes <-> human should not break.
  local h b
  h="$(bytes_to_human_nospace 1048576 2>/dev/null || true)"
  b="$(human_to_bytes "${h}" 2>/dev/null || true)"
  if [[ -z "$h" || -z "$b" || ! "$b" =~ ^[0-9]+$ ]]; then
    warn "Selftest: human/bytes formatter sanity failed; forcing safe UI mode."
    CFG_COLOR="false"
    init_colors
  fi

  # Layout A/B: ensure header keeps tail columns visible under common widths.
  # (If this fails, table may truncate; we still keep the console alive.)
  local cols_try
  for cols_try in 80 100 120; do
    local namew fixed spaces w
    namew="$(dash_name_width "$cols_try")"
    fixed=$((6 + 3 + 8 + 8 + 9 + 9 + 10 + 5 + 5))  # conservative mid profile
    spaces=9
    w=$(( fixed + spaces + namew ))
    if (( w > cols_try + 10 )); then
      warn "Selftest: table layout may truncate at cols=${cols_try} (computed=${w})."
      break
    fi
  done
}

header() {
  # Clear screen and print a consistent header.
  # Always reflect latest config + theme.
  init_colors
  # Must be safe even when stdout/stderr are redirected.
  if has clear; then clear || true; else printf "\033c" 2>/dev/null || true; fi
  printf "%s%s%s %s(v%s)%s\n" "${C_BOLD}" "${APP_NAME}" "${C_RESET}" "${C_DIM}" "${APP_VER}" "${C_RESET}"
  hr
}


hr() {
  local cols
  cols="$(ui_cols)"
  printf "%s%s%s\n" "${C_BLUE}" "$(repeat_char "$cols" "-")" "${C_RESET}"
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

# UI sizing helpers
term_cols() {
  local c=120
  if has tput; then
    c="$(tput cols 2>/dev/null || echo 120)"
  fi
  [[ "$c" =~ ^[0-9]+$ ]] || c=120
  echo "$c"
}

repeat_char() {
  local n="${1:-0}" ch="${2:- }"
  # Robustness: callers may pass placeholders; treat non-numeric as 0.
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    n=0
  fi
  (( n <= 0 )) && { printf ""; return; }
  printf "%*s" "$n" "" | tr " " "$ch"
}

visible_len() {
  # Return approximate visible length (strip ANSI color sequences).
  # Note: unicode wide chars may still differ; keep headers ASCII-only to stay safe.
  local x="${1:-}"
  x="$(sed -E 's/\[[0-9;]*m//g' <<<"$x")"
  echo "${#x}"
}

print_lr_line() {
  # Print left text and right text on the same line within ui_cols (hard width cap).
  # Right side may be truncated; we avoid breaking ANSI by assuming right is mostly ASCII.
  local left="$1" right="$2"
  local cols; cols="$(ui_cols)"

  local llen rlen avail pad
  llen="$(visible_len "$left")"
  rlen="$(visible_len "$right")"
  avail=$(( cols - llen - 1 ))
  (( avail < 0 )) && avail=0

  if (( rlen > avail )); then
    # Truncate using ANSI-stripped view to avoid cutting escape sequences.
    local right_plain
    right_plain="$(sed -E 's/\x1B\[[0-9;]*m//g' <<<"$right")"
    right_plain="${right_plain:0:avail}"
    right="$right_plain"
    rlen="${#right_plain}"
  fi

  pad=$(( cols - llen - rlen ))
  (( pad < 1 )) && pad=1
  printf "%s%*s%s\n" "$left" "$pad" "" "$right"
}


sanitize_line() {
  # Hard guard: never print shaded blocks even if a regression reintroduces them.
  # Prefer box-drawing line for separators; degrade only shaded blocks.
  local s="${1:-}"
  s="${s//▒/─}"
  printf "%s" "$s"
}

term_enter_alt() { tput smcup 2>/dev/null || true; tput civis 2>/dev/null || true; }
term_exit_alt()  { tput cnorm 2>/dev/null || true; tput rmcup 2>/dev/null || true; }

read_key() {
  # Non-blocking key reader. Emits: F8/F9/F10/F12 or empty.
  local k=""
  read -rsn1 -t 0.05 k </dev/tty || { echo ""; return; }
  if [[ "$k" == $'\e' ]]; then
    local k2 k3 seq=""
    read -rsn1 -t 0.05 k2 </dev/tty || { echo ""; return; }
    if [[ "$k2" == "[" ]]; then
      # Read until '~' or a small cap.
      for _ in 1 2 3 4 5; do
        read -rsn1 -t 0.02 k3 </dev/tty || break
        seq+="$k3"
        [[ "$k3" == "~" ]] && break
      done
      case "$seq" in
        "20~") echo "F9" ;;
        "21~") echo "F10" ;;
        "19~") echo "F8" ;;
        "23~") echo "F11" ;;
        "24~") echo "F12" ;;
        *) echo "" ;;
      esac
      return
    fi
    echo ""
    return
  fi
  case "$k" in
    q|Q) echo "F10" ;;
    p|P) echo "F8" ;;
    v|V) echo "F9" ;;
    c|C) echo "F12" ;;
    *) echo "" ;;
  esac
}


mem_usage_bytes() {
  # Echo: used_bytes|total_bytes|avail_bytes
  local mt ma
  mt="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  ma="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  # Values are in kB.
  mt=$((mt * 1024))
  ma=$((ma * 1024))
  local used=$((mt - ma))
  (( used < 0 )) && used=0
  echo "${used}|${mt}|${ma}"
}

format_mem_line() {
  # Build: MEM used/total (human) + percentage (ASCII safe)
  local used="$1" total="$2"
  local uh th
  uh="$(bytes_to_human_nospace "$used")"
  th="$(bytes_to_human_nospace "$total")"
  local pct=0
  if (( total > 0 )); then pct=$(( used * 100 / total )); fi
  printf "MEM %s/%s (%s%%)" "$uh" "$th" "$pct"
}

bottom_menu_bar() {
  local cols; cols="$(ui_cols)"
  local view="${1:-ALL}"
  local paused="${2:-0}"
  local compact="${3:-0}"
  local mode="VIEW:${view}"
  [[ "$paused" == "1" ]] && mode+="  PAUSED"
  [[ "$compact" == "1" ]] && mode+="  COMPACT"
  local msg="F9 View  F10 Exit  F8 Pause  F12 Compact"
  local left="${C_BOLD}${msg}${C_RESET}"
  local right="${C_DIM}${mode}${C_RESET}"
  # Reverse video like htop, but keep within width.
  local line
  line="$(printf "%s" "$(sanitize_line "$left")")"
  # Use print_lr_line to align; wrap with reverse.
  tput rev 2>/dev/null || true
  print_lr_line "$left" "$right"
  tput sgr0 2>/dev/null || true
}


ui_cols() {
  local cols
  cols="$(term_cols)"
  # Respect explicit override, then cap to terminal width
  if [[ "${UI_MAX_COLS}" =~ ^[0-9]+$ ]] && (( UI_MAX_COLS > 0 )); then
    if (( cols > UI_MAX_COLS )); then cols=$UI_MAX_COLS; fi
  fi
  (( cols < 60 )) && cols=60
  echo "$cols"
}

dash_name_width() {
  local cols="${1:-$(ui_cols)}"
  # Compute NAME column width dynamically so the whole row fits within ui_cols.
  # Fixed part excludes NAME but includes all spaces between columns.
  # Columns: TYPE NAME ST Connecting Connected Up Down Uptime -m -b
  local fixed=$((6 + 3 + 11 + 10 + 10 + 10 + 11 + 5 + 5))
  local spaces=9
  local namew=$((cols - fixed - spaces))
  (( namew < 6 )) && namew=6
  (( namew > 32 )) && namew=32
  echo "$namew"
}



# ------------------------- Config persistence (single KV file) -----------------
# Rule: All settings and user selections are persisted to CFG_FILE and reloaded when needed.
# No external deps (jq) are used.

cfg_key_set() {
  # Usage: cfg_key_set KEY VALUE
  local k="$1" v="$2"
  case "$k" in
    NET_IFACE)        CFG_NET_IFACE="$v" ;;
    REFRESH_SECS)     CFG_REFRESH_SECS="$v" ;;
    LOG_TAIL)         CFG_LOG_TAIL="$v" ;;
    COLOR)            CFG_COLOR="$v" ;;
    VIEW_DEFAULT)     CFG_VIEW_DEFAULT="$v" ;;
    COMPACT_DEFAULT)  CFG_COMPACT_DEFAULT="$v" ;;
    STATS_TTL)        CFG_STATS_TTL="$v" ;;
    MAX_JOBS)         CFG_MAX_JOBS="$v" ;;
    MAX_LOG_JOBS)     CFG_MAX_LOG_JOBS="$v" ;;
    CONSOLE_COLS)     CFG_CONSOLE_COLS="$v"; UI_MAX_COLS="$v" ;;
    OPT_TARGET_NAME)  CFG_OPT_TARGET_KEYWORD="$v" ;;
    OPT_DOCKER_PRI)   CFG_OPT_DOCKER_PRI="$v" ;;
    OPT_NATIVE_PRI)   CFG_OPT_NATIVE_PRI="$v" ;;
    OPT_VERBOSE)      CFG_OPT_VERBOSE="$v" ;;
    HEALTH_LAST_RUN)  CFG_HEALTH_LAST_RUN="$v" ;;
    HEALTH_OK)        CFG_HEALTH_OK="$v" ;;
    HEALTH_SUMMARY)   CFG_HEALTH_SUMMARY="$v" ;;
    COLOR_DOCKER)     CFG_COLOR_DOCKER="$v" ;;
    COLOR_NATIVE)     CFG_COLOR_NATIVE="$v" ;;
    COLOR_TITLE)      CFG_COLOR_TITLE="$v" ;;
    COLOR_HEADER)     CFG_COLOR_HEADER="$v" ;;
    LEGEND_ACTIVE)    CFG_COLOR_LEGEND_ACTIVE="$v" ;;
    LEGEND_IDLE)      CFG_COLOR_LEGEND_IDLE="$v" ;;
    LEGEND_DOWN)      CFG_COLOR_LEGEND_DOWN="$v" ;;
    NIC_LABEL)        CFG_COLOR_NIC_LABEL="$v" ;;
    NIC_RX)           CFG_COLOR_NIC_RX="$v" ;;
    NIC_TX)           CFG_COLOR_NIC_TX="$v" ;;
    *) return 0 ;;
  esac
}

cfg_sanitize_value() {
  # Strip CR, leading/trailing spaces.
  local v="${1:-}"
  v="${v//$'
'/}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf "%s" "$v"
}

cfg_import_legacy_json() {
  # Best-effort one-time migration from legacy JSON (no jq dependency).
  local jf="$CONFIG_FILE"
  [[ -e "$CFG_FILE" ]] && return 0
  [[ -r "$jf" ]] || return 0

  local net refresh tail color view compact
  net="$(awk -F'"' '/"net_iface"[[:space:]]*:/ {print $4; exit}' "$jf" 2>/dev/null || true)"
  refresh="$(awk -F'[: ,]+' '/"refresh_secs"[[:space:]]*:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' "$jf" 2>/dev/null || true)"
  tail="$(awk -F'[: ,]+' '/"log_tail"[[:space:]]*:/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' "$jf" 2>/dev/null || true)"
  color="$(awk -F'[: ,]+' '/"color"[[:space:]]*:/ {for(i=1;i<=NF;i++) if($i ~ /^(true|false)$/){print $i; exit}}' "$jf" 2>/dev/null || true)"
  view="$(awk -F'"' '/"view"[[:space:]]*:/ {print $4; exit}' "$jf" 2>/dev/null || true)"
  compact="$(awk -F'[: ,]+' '/"compact"[[:space:]]*:/ {for(i=1;i<=NF;i++) if($i ~ /^[01]$/){print $i; exit}}' "$jf" 2>/dev/null || true)"

  cfg_ensure_dir
  {
    printf '%s\n' '# Conduit-console config (migrated from legacy json)'
    [[ -n "$net" ]] && printf 'NET_IFACE=%s\n' "$net"
    [[ -n "$refresh" ]] && printf 'REFRESH_SECS=%s\n' "$refresh"
    [[ -n "$tail" ]] && printf 'LOG_TAIL=%s\n' "$tail"
    [[ -n "$color" ]] && printf 'COLOR=%s\n' "$color"
    [[ -n "$view" ]] && printf 'VIEW_DEFAULT=%s\n' "$view"
    [[ -n "$compact" ]] && printf 'COMPACT_DEFAULT=%s\n' "$compact"
  } > "$CFG_FILE" 2>/dev/null || true
}


cfg_write_default() {
  cfg_ensure_dir
  local f="$CFG_FILE"
  [[ -e "$f" ]] && return 0
  {
    printf '%s
' '# Conduit-console config (key=value)'
    printf '%s
' '# NOTE: Edit carefully. Unknown keys are ignored.'
    printf 'NET_IFACE=%s
' "$NET_IFACE_DEFAULT"
    printf 'REFRESH_SECS=%s
' "$REFRESH_SECS_DEFAULT"
    printf 'CONSOLE_COLS=%s
' \"$UI_MAX_COLS_DEFAULT\"
    printf 'LOG_TAIL=%s
' "200"
    printf 'COLOR=%s
' "true"
    printf 'VIEW_DEFAULT=%s
' "ALL"
    printf 'COMPACT_DEFAULT=%s
' "0"
    printf 'STATS_TTL=%s
' "15"
    printf 'MAX_JOBS=%s
' "${CFG_MAX_JOBS_DEFAULT}"
    printf 'MAX_LOG_JOBS=%s
' "4"
    # Theme colors
    printf 'COLOR_DOCKER=%s
' "$CFG_COLOR_DOCKER"
    printf 'COLOR_NATIVE=%s
' "blue"
    printf 'COLOR_TITLE=%s
' "$CFG_COLOR_TITLE"
    printf 'COLOR_HEADER=%s
' "$CFG_COLOR_HEADER"
    printf 'LEGEND_ACTIVE=%s
' "$CFG_COLOR_LEGEND_ACTIVE"
    printf 'LEGEND_IDLE=%s
' "$CFG_COLOR_LEGEND_IDLE"
    printf 'LEGEND_DOWN=%s
' "$CFG_COLOR_LEGEND_DOWN"
    printf 'NIC_LABEL=%s
' "$CFG_COLOR_NIC_LABEL"
    printf 'NIC_RX=%s
' "$CFG_COLOR_NIC_RX"
    printf 'NIC_TX=%s
' "$CFG_COLOR_NIC_TX"
    # Optimizer
    printf 'OPT_TARGET_NAME=%s
' "$OPT_TARGET_KEYWORD_DEFAULT"
    printf 'OPT_DOCKER_PRI=%s
' "$OPT_DOCKER_PRI_DEFAULT"
    printf 'OPT_NATIVE_PRI=%s
' "$OPT_NATIVE_PRI_DEFAULT"
    printf 'OPT_VERBOSE=%s
' "$OPT_VERBOSE_DEFAULT"
    # Health snapshot (program internal)
    printf 'HEALTH_LAST_RUN=%s
' ""
    printf 'HEALTH_OK=%s
' "false"
    printf 'HEALTH_SUMMARY=%s
' ""
  } > "$f" 2>/dev/null || true
}

cfg_load_all() {
  cfg_import_legacy_json
  cfg_write_default
  cfg_ensure_dir
  local f="$CFG_FILE"
  [[ -r "$f" ]] || return 0

  # Reset to safe defaults before apply.
  CFG_NET_IFACE="$NET_IFACE_DEFAULT"
  CFG_REFRESH_SECS="$REFRESH_SECS_DEFAULT"
  CFG_CONSOLE_COLS="$UI_MAX_COLS_DEFAULT"; UI_MAX_COLS="$CFG_CONSOLE_COLS"
  CFG_LOG_TAIL="200"
  CFG_COLOR="true"
  CFG_VIEW_DEFAULT="ALL"
  CFG_COMPACT_DEFAULT="0"
  CFG_STATS_TTL="15"
  CFG_MAX_JOBS="${CFG_MAX_JOBS_DEFAULT}"
  CFG_MAX_LOG_JOBS="4"
  CFG_OPT_TARGET_KEYWORD="$OPT_TARGET_KEYWORD_DEFAULT"
  CFG_OPT_DOCKER_PRI="$OPT_DOCKER_PRI_DEFAULT"
  CFG_OPT_NATIVE_PRI="$OPT_NATIVE_PRI_DEFAULT"
  CFG_OPT_VERBOSE="$OPT_VERBOSE_DEFAULT"

  while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
    case "$k" in \#*) continue ;; esac
    k="${k//[[:space:]]/}"
    v="$(cfg_sanitize_value "$v")"
    cfg_key_set "$k" "$v" || true
  done < "$f"

  # Validate critical numeric ranges (hard-safe).
  [[ "$CFG_REFRESH_SECS" =~ ^[0-9]+$ ]] || CFG_REFRESH_SECS="$REFRESH_SECS_DEFAULT"
  (( CFG_REFRESH_SECS < 1 )) && CFG_REFRESH_SECS=1
  (( CFG_REFRESH_SECS > 300 )) && CFG_REFRESH_SECS=300

  [[ "$CFG_LOG_TAIL" =~ ^[0-9]+$ ]] || CFG_LOG_TAIL="200"
  (( CFG_LOG_TAIL < 10 )) && CFG_LOG_TAIL=10
  (( CFG_LOG_TAIL > 5000 )) && CFG_LOG_TAIL=5000

  [[ "$CFG_MAX_JOBS" =~ ^[0-9]+$ ]] || CFG_MAX_JOBS="${CFG_MAX_JOBS_DEFAULT}"
  (( CFG_MAX_JOBS < 2 )) && CFG_MAX_JOBS=2
  (( CFG_MAX_JOBS > 40 )) && CFG_MAX_JOBS=40

  [[ "$CFG_MAX_LOG_JOBS" =~ ^[0-9]+$ ]] || CFG_MAX_LOG_JOBS=4
  (( CFG_MAX_LOG_JOBS < 1 )) && CFG_MAX_LOG_JOBS=1
  (( CFG_MAX_LOG_JOBS > 20 )) && CFG_MAX_LOG_JOBS=20

  [[ "$CFG_CONSOLE_COLS" =~ ^[0-9]+$ ]] || CFG_CONSOLE_COLS="$UI_MAX_COLS_DEFAULT"
  (( CFG_CONSOLE_COLS < 60 )) && CFG_CONSOLE_COLS=60
  (( CFG_CONSOLE_COLS > 400 )) && CFG_CONSOLE_COLS=400
  UI_MAX_COLS="$CFG_CONSOLE_COLS"

  [[ "$CFG_STATS_TTL" =~ ^[0-9]+$ ]] || CFG_STATS_TTL=15
  (( CFG_STATS_TTL < 2 )) && CFG_STATS_TTL=2
  (( CFG_STATS_TTL > 300 )) && CFG_STATS_TTL=300

  # iface override via CLI is applied in parse_args; keep if valid.
  if ! iface_exists "$CFG_NET_IFACE"; then
    CFG_NET_IFACE="$(default_iface)"
  fi
}

cfg_save_all() {
  cfg_ensure_dir
  local f="$CFG_FILE"
  {
    printf '%s
' '# Conduit-console config (key=value)'
    printf 'NET_IFACE=%s
' "$CFG_NET_IFACE"
    printf 'REFRESH_SECS=%s
' "$CFG_REFRESH_SECS"
    printf 'CONSOLE_COLS=%s
' \"$CFG_CONSOLE_COLS\"
    printf 'LOG_TAIL=%s
' "$CFG_LOG_TAIL"
    printf 'COLOR=%s
' "$CFG_COLOR"
    printf 'VIEW_DEFAULT=%s
' "${CFG_VIEW_DEFAULT:-ALL}"
    printf 'COMPACT_DEFAULT=%s
' "${CFG_COMPACT_DEFAULT:-0}"
    printf 'STATS_TTL=%s
' "$CFG_STATS_TTL"
    printf 'MAX_JOBS=%s
' "${CFG_MAX_JOBS:-$CFG_MAX_JOBS_DEFAULT}"
    printf 'MAX_LOG_JOBS=%s
' "${CFG_MAX_LOG_JOBS:-4}"
    # Theme
    printf 'COLOR_DOCKER=%s
' "$CFG_COLOR_DOCKER"
    printf 'COLOR_NATIVE=%s
' "$CFG_COLOR_NATIVE"
    printf 'COLOR_TITLE=%s
' "$CFG_COLOR_TITLE"
    printf 'COLOR_HEADER=%s
' "$CFG_COLOR_HEADER"
    printf 'LEGEND_ACTIVE=%s
' "$CFG_COLOR_LEGEND_ACTIVE"
    printf 'LEGEND_IDLE=%s
' "$CFG_COLOR_LEGEND_IDLE"
    printf 'LEGEND_DOWN=%s
' "$CFG_COLOR_LEGEND_DOWN"
    printf 'NIC_LABEL=%s
' "$CFG_COLOR_NIC_LABEL"
    printf 'NIC_RX=%s
' "$CFG_COLOR_NIC_RX"
    printf 'NIC_TX=%s
' "$CFG_COLOR_NIC_TX"
    # Optimizer
    printf 'OPT_TARGET_NAME=%s
' "$CFG_OPT_TARGET_KEYWORD"
    printf 'OPT_DOCKER_PRI=%s
' "$CFG_OPT_DOCKER_PRI"
    printf 'OPT_NATIVE_PRI=%s
' "$CFG_OPT_NATIVE_PRI"
    printf 'OPT_VERBOSE=%s
' "$CFG_OPT_VERBOSE"
    # Health snapshot
    printf 'HEALTH_LAST_RUN=%s
' "${CFG_HEALTH_LAST_RUN:-}"
    printf 'HEALTH_OK=%s
' "${CFG_HEALTH_OK:-false}"
    printf 'HEALTH_SUMMARY=%s
' "${CFG_HEALTH_SUMMARY:-}"
  } > "$f" 2>/dev/null || true
}

# Backward compatible wrappers used by menus
config_load() { cfg_load_all; }
config_save_network_iface(){ CFG_NET_IFACE="$1"; cfg_save_all; }
config_save_console_refresh(){ CFG_REFRESH_SECS="$1"; cfg_save_all; }
config_save_console_logtail(){ CFG_LOG_TAIL="$1"; cfg_save_all; }
config_save_console_color(){ CFG_COLOR="$1"; cfg_save_all; }

config_save_health_snapshot(){
  local ok="$1" summary="$2"
  CFG_HEALTH_LAST_RUN="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  CFG_HEALTH_OK="$ok"
  CFG_HEALTH_SUMMARY="$summary"
  cfg_save_all
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
  info "Loading config: ${CFG_FILE}"
  config_load
  init_colors

  info "Running minimal preflight..."
  preflight_minimal

  info "Updating internal health snapshot..."
  health_run_snapshot || true

  ok "Precondition checks passed"
}


health_report_path() { echo "${RUN_ROOT}/health_report.txt"; }

health_quick_tools() {
  header
  printf "%sQuick Tool Check%s\n\n" "${C_BOLD}" "${C_RESET}"
  local tools=(bash awk sed grep tr cut sort uniq wc head tail date stat tput clear stty systemctl journalctl timeout docker pgrep ps renice ionice mkdir rm install mktemp sleep)
  # Some tools are optional; presence will be reported.
  local okc=0 failc=0
  for c in "${tools[@]}"; do
    if has "$c"; then
      printf "  %-12s : %sOK%s\n" "$c" "${C_OK}" "${C_RESET}"
      ((okc++)) || true
    else
      printf "  %-12s : %sMISSING%s\n" "$c" "${C_ERR}" "${C_RESET}"
      ((failc++)) || true
    fi
  done
  echo
  printf "Summary: %s OK, %s missing\n" "$okc" "$failc"
}

health_run_snapshot() {
  # Minimal internal snapshot for status line; lightweight.
  local ok_all="true"
  local miss=()
  for c in bash systemctl journalctl awk sed grep; do
    if ! has "$c"; then ok_all="false"; miss+=("$c"); fi
  done

  # Config file sanity
  if [[ ! -r "$CFG_FILE" ]]; then ok_all="false"; miss+=("config"); fi

  if [[ "$ok_all" == "true" ]]; then
    config_save_health_snapshot true "OK (tools+config)"
  else
    config_save_health_snapshot false "Issues: ${miss[*]}"
  fi
}

health_collect_rows() {
  # Emits rows as: CATEGORY|ITEM|STATUS|DETAIL
  local cols; cols="$(ui_cols)"
  local now; now="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"

  echo "META|Timestamp|OK|$now"
  echo "CONFIG|File|$([[ -r "$CFG_FILE" && -w "$CFG_FILE" ]] && echo OK || echo WARN)|$CFG_FILE"
  echo "CONFIG|Reload|OK|All settings loaded from config file"

  # Tools
  local tools=(bash awk sed grep tput systemctl journalctl date stat)
  if has docker; then tools+=(docker); fi
  for c in "${tools[@]}"; do
    if has "$c"; then
      echo "TOOLS|$c|OK|$(command -v "$c" 2>/dev/null)"
    else
      echo "TOOLS|$c|FAIL|not found"
    fi
  done

  # Native units
  local u
  local any_native="false"
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    any_native="true"
    local st; st="$(systemctl is-active "$u" 2>/dev/null || echo "unknown")"
    local status="OK"
    [[ "$st" != "active" ]] && status="WARN"
    # stats freshness (cache age)
    local key; key="$(stats_cache_key_safe "$u")"
    local cfile; cfile="$(stats_cache_dir)/native.${key}.stats"
    local line="" age=999999 ttl; ttl="$(stats_cache_ttl_effective)"
    if line="$(stats_cache_read "$cfile" 2>/dev/null)"; then age="${_CACHE_AGE:-999999}"; fi
    local freshness="fresh"
    (( age > ttl )) && freshness="stale"
    echo "NATIVE|$u|$status|state=$st, stats=$freshness(age=${age}s)"
  done < <(list_native_units 2>/dev/null || true)
  [[ "$any_native" == "false" ]] && echo "NATIVE|conduit*.service|WARN|no matching systemd units found"

  # Docker containers
  if has docker && docker_ok; then
    local c
    local any_docker="false"
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      any_docker="true"
      local running="false"
      docker inspect -f '{{.State.Running}}' "$c" >/dev/null 2>&1 && running="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)"
      local status="OK"
      [[ "$running" != "true" ]] && status="WARN"
      local key; key="$(stats_cache_key_safe "$c")"
      local cfile; cfile="$(stats_cache_dir)/docker.${key}.stats"
      local line="" age=999999 ttl; ttl="$(stats_cache_ttl_effective)"
      if line="$(stats_cache_read "$cfile" 2>/dev/null)"; then age="${_CACHE_AGE:-999999}"; fi
      local freshness="fresh"
      (( age > ttl )) && freshness="stale"
      echo "DOCKER|$c|$status|running=$running, stats=$freshness(age=${age}s)"
    done < <(list_docker_conduits_running 2>/dev/null || true)
    [[ "$any_docker" == "false" ]] && echo "DOCKER|conduit containers|WARN|none detected via docker ps"
  else
    echo "DOCKER|Engine|WARN|docker not available or daemon not reachable"
  fi
}

health_format_table() {
  # Reads rows from stdin, prints a table aligned to ui_cols.
  local cols; cols="$(ui_cols)"
  local w_cat=10 w_item=28 w_st=6
  local w_detail=$(( cols - w_cat - w_item - w_st - 6 ))
  (( w_detail < 20 )) && w_detail=20

  printf "
%s
" "$(repeat_char "$cols" "-")"
  printf "%-${w_cat}.${w_cat}s  %-${w_item}.${w_item}s  %-${w_st}.${w_st}s  %s
" "CAT" "ITEM" "ST" "DETAIL"
  printf "%s
" "$(repeat_char "$cols" "-")"

  local line cat item st detail
  while IFS='|' read -r cat item st detail; do
    [[ -z "${cat}${item}${st}${detail}" ]] && continue
    printf "%-${w_cat}.${w_cat}s  %-${w_item}.${w_item}s  %-${w_st}.${w_st}s  %-${w_detail}.${w_detail}s
" \
      "$cat" "$item" "$st" "$detail"
  done

  printf "%s
" "$(repeat_char "$cols" "-")"
}

health_run_full() {
  header
  printf "%sHealth & Diagnostics Report%s\n\n" "${C_BOLD}" "${C_RESET}"

  local tmp; tmp="$(mktemp -p "$RUN_ROOT" health.XXXXXX 2>/dev/null || echo "${RUN_ROOT}/health.tmp")"
  health_collect_rows > "$tmp" 2>/dev/null || true

  health_format_table < "$tmp"

  # Summarize and persist snapshot.
  local fails warns
  fails="$(grep -c '|FAIL|' "$tmp" 2>/dev/null || echo 0)"
  warns="$(grep -c '|WARN|' "$tmp" 2>/dev/null || echo 0)"
  local ok_flag="true"
  (( fails > 0 )) && ok_flag="false"
  local summary="fails=${fails}, warns=${warns}"
  config_save_health_snapshot "$ok_flag" "$summary"

  # persist report
  cp -f "$tmp" "$(health_report_path)" 2>/dev/null || true
  rm -f "$tmp" 2>/dev/null || true
}

health_show_last() {
  header
  printf "%sLast Health Report%s\n\n" "${C_BOLD}" "${C_RESET}"
  local p; p="$(health_report_path)"
  if [[ -s "$p" ]]; then
    health_format_table < "$p"
  else
    echo "No stored report found. Run a health check first."
  fi
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


stats_cache_dir() { echo "${RUN_ROOT}/cache"; }

stats_cache_key_safe() {
  # Map arbitrary unit/container name to safe filename component.
  local s="${1:-}"
  s="${s//[^a-zA-Z0-9_.-]/_}"
  printf "%s" "$s"
}

stats_cache_ttl_effective() {
  local ttl="${CFG_STATS_TTL:-15}"
  local min=$(( (CFG_REFRESH_SECS > 0 ? CFG_REFRESH_SECS : 5) * 2 ))
  (( ttl < min )) && ttl="$min"
  (( ttl < 2 )) && ttl=2
  (( ttl > 300 )) && ttl=300
  echo "$ttl"
}

stats_cache_read() {
  # Usage: stats_cache_read <path>  -> prints cached_line and sets global _CACHE_AGE
  local path="$1"
  _CACHE_AGE=999999
  [[ -r "$path" ]] || return 1
  local line ts payload
  line="$(head -n1 "$path" 2>/dev/null || true)"
  ts="${line%%|*}"
  payload="${line#*|}"
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  _CACHE_AGE=$(( now - ts ))
  printf "%s" "$payload"
  return 0
}

stats_cache_write() {
  # Usage: stats_cache_write <path> <payload>
  local path="$1" payload="$2"
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  mkdir -p "$(dirname "$path")" >/dev/null 2>&1 || true
  printf "%s|%s
" "$now" "$payload" > "$path" 2>/dev/null || true
}

last_stats_native() {
  local unit="$1"
  local ttl; ttl="$(stats_cache_ttl_effective)"
  local key; key="$(stats_cache_key_safe "$unit")"
  local cfile; cfile="$(stats_cache_dir)/native.${key}.stats"

  local cached="" age=999999
  if cached="$(stats_cache_read "$cfile" 2>/dev/null)"; then
    age="${_CACHE_AGE:-999999}"
    if (( age <= ttl )) && [[ -n "$cached" ]]; then
      printf "%s" "$cached"
      return 0
    fi
  fi

  # Fetch last [STATS] line. Use awk (single process) to keep it cheap.
  local line=""
  line="$(journalctl -u "$unit" -n "${CFG_LOG_TAIL:-200}" --no-pager -o cat 2>/dev/null | awk '/\[STATS\]/{l=$0} END{print l}' || true)"

  if [[ -n "$line" ]]; then
    stats_cache_write "$cfile" "$line"
    printf "%s" "$line"
    return 0
  fi

  # Fallback to any cached line (even if stale) to avoid blank columns.
  if [[ -n "$cached" ]]; then
    printf "%s" "$cached"
  fi
  return 0
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

# List only running conduit containers (source of truth = Docker runtime)
list_docker_conduits_running() {
  # Always read from Docker directly reminder: be inclusive, names differ across installs.
  docker ps --format '{{.Names}}' 2>/dev/null | grep -i 'conduit' || true
}

# List all conduit containers (running + stopped)
list_docker_conduits_all() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(conduit[0-9]+|Conduit[0-9]+\.docker)$' || true
}

docker_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "unknown"
}

last_stats_docker() {
  local cname="$1"
  local ttl; ttl="$(stats_cache_ttl_effective)"
  local key; key="$(stats_cache_key_safe "$cname")"
  local cfile; cfile="$(stats_cache_dir)/docker.${key}.stats"

  local cached="" age=999999
  if cached="$(stats_cache_read "$cfile" 2>/dev/null)"; then
    age="${_CACHE_AGE:-999999}"
    if (( age <= ttl )) && [[ -n "$cached" ]]; then
      printf "%s" "$cached"
      return 0
    fi
  fi

  local line=""
  line="$(docker logs --tail "${CFG_LOG_TAIL:-200}" "$cname" 2>/dev/null | awk '/\[STATS\]/{l=$0} END{print l}' || true)"

  if [[ -n "$line" ]]; then
    stats_cache_write "$cfile" "$line"
    printf "%s" "$line"
    return 0
  fi

  if [[ -n "$cached" ]]; then
    printf "%s" "$cached"
  fi
  return 0
}


docker_instance_conf_path() {
  local inst="$1"
  echo "${DOCKER_INSTANCES_DIR}/${inst}/instance.conf"
}

docker_load_instance_conf() {
  # shellcheck disable=SC1090
  local conf="$1"
  [[ -f "$conf" ]] || return 1

  CONTAINER_NAME=""
  VOLUME_NAME=""
  NETWORK_MODE=""
  PORT_ARGS=""
  DATA_MOUNT=""
  RUN_ARGS=""

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
DATA_MOUNT="${DATA_MOUNT}"       # e.g., /home/conduit/data
RUN_ARGS="${RUN_ARGS}"           # e.g., start -m 250 -b -1
EOF
}

# Prefer reading -m/-b from the running container process, fallback to config
docker_get_m_b_runtime() {
  local container="$1"

  # Parse argv of the conduit process inside the container (best effort)
  local cmdline=""
  cmdline="$(docker exec "$container" sh -lc "ps -o args= -C conduit 2>/dev/null | head -n1" 2>/dev/null || true)"
  if [[ -n "$cmdline" ]]; then
    local m="-" b="-"
    if [[ "$cmdline" =~ ([-][m][[:space:]]+)([^[:space:]]+) ]]; then m="${BASH_REMATCH[2]}"; fi
    if [[ "$cmdline" =~ ([-][b][[:space:]]+)([^[:space:]]+) ]]; then b="${BASH_REMATCH[2]}"; fi
    echo "$m" "$b"
    return 0
  fi

  echo "- -"
  return 0
}


docker_get_m_b_inspect() {
  # Prefer parsing from docker inspect (no docker exec overhead).
  local container="$1"
  local cmdline=""
  cmdline="$(docker inspect -f '{{range .Config.Entrypoint}}{{.}} {{end}}{{range .Config.Cmd}}{{.}} {{end}}' "$container" 2>/dev/null || true)"
  local m="-" b="-"
  if [[ "$cmdline" =~ ([-][m][[:space:]]+)([^[:space:]]+) ]]; then m="${BASH_REMATCH[2]}"; fi
  if [[ "$cmdline" =~ ([-][b][[:space:]]+)([^[:space:]]+) ]]; then b="${BASH_REMATCH[2]}"; fi
  echo "$m" "$b"
}

docker_get_m_b_from_conf() {
  local inst="$1"
  local conf
  conf="$(docker_instance_conf_path "$inst")"
  docker_load_instance_conf "$conf" || { echo "- -"; return 0; }

  local m="-" b="-"
  if [[ "${RUN_ARGS:-}" =~ ([-][m][[:space:]]+)([^[:space:]]+) ]]; then m="${BASH_REMATCH[2]}"; fi
  if [[ "${RUN_ARGS:-}" =~ ([-][b][[:space:]]+)([^[:space:]]+) ]]; then b="${BASH_REMATCH[2]}"; fi
  echo "$m" "$b"
}

docker_pull_latest() {
  need_root || return 1
  docker_available || { err "Docker not available."; return 1; }
  ok "Pulling image: ${DOCKER_IMAGE}"
  if ! docker pull "${DOCKER_IMAGE}" 2>&1; then
    err "docker pull failed: ${DOCKER_IMAGE}"
    return 1
  fi
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

  local -a args=()
  # Split RUN_ARGS safely into argv
  local IFS=" "
  read -r -a args <<<"${RUN_ARGS}"

  local out rc
  out="$(docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    "${net_args[@]}" \
    -v "$VOLUME_NAME":"$DATA_MOUNT" \
    "$DOCKER_IMAGE" "${args[@]}" 2>&1)"; rc=$?

  if (( rc == 0 )); then
    ok "Container started: $CONTAINER_NAME"
  else
    err "docker run failed (rc=${rc})."
    printf "%s\n" "$out"
    return $rc
  fi
  return 0
}

docker_create_instance() {
  need_root || return 0
  docker_available || { err "Docker not available."; pause_enter; return 0; }
  mkdir -p "${DOCKER_INSTANCES_DIR}" >/dev/null 2>&1 || true

  docker_pull_latest || { pause_enter; return 0; }

  header
  printf "%sCreate New Docker Instance%s\n\n" "${C_BOLD}" "${C_RESET}"
  printf "%sNaming:%s container=Conduit<NUM>.docker | folder=docker-instances/conduit<NUM>/ | volume=conduit<NUM>-data\n\n" "${C_DIM}" "${C_RESET}"

  local num m bw
  while true; do
    read -r -p "Instance number (e.g., 250) (0=Back): " num </dev/tty || true
    [[ "${num:-}" == "0" ]] && return 0
    [[ "${num:-}" =~ ^[0-9]+$ ]] && break
  done

  local inst="conduit${num}"
  local inst_dir="${DOCKER_INSTANCES_DIR}/${inst}"
  local conf="${inst_dir}/instance.conf"

  if [[ -d "$inst_dir" ]]; then
    warn "Instance directory already exists: $inst_dir"
    pause_enter
    return 0
  fi

  read -r -p "Max clients (-m) [default=${num}]: " m </dev/tty || true
  [[ -z "${m}" ]] && m="${num}"
  [[ "${m}" =~ ^[0-9]+$ ]] || { warn "Invalid -m"; pause_enter; return 0; }

  read -r -p "Bandwidth (-b) 2..40 (ENTER=Unlimited -> -1 shown as ∞): " bw </dev/tty || true
  if [[ -z "${bw}" ]]; then
    bw="-1"
  else
    [[ "${bw}" =~ ^-1$|^[0-9]+(\.[0-9]+)?$ ]] || { warn "Invalid -b"; pause_enter; return 0; }
  fi

  mkdir -p "$inst_dir" >/dev/null 2>&1 || true

  CONTAINER_NAME="Conduit${num}.docker"
  VOLUME_NAME="conduit${num}-data"
  NETWORK_MODE="host"
  PORT_ARGS=""
  DATA_MOUNT="/home/conduit/data"

  # Standard runtime command (no extra quoting, no '/bin/sh -lc'):
  RUN_ARGS="start -m ${m} -b ${bw}"

  docker_write_instance_conf "$conf"

  ok "Creating volume: ${VOLUME_NAME}"
  docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || docker volume create "$VOLUME_NAME" >/dev/null 2>&1 || true

  docker_run_from_conf "$inst" || true

  ok "Created docker instance: ${inst} (${CONTAINER_NAME})"
  pause_enter
}

docker_single_action() {
  need_root || return 0
  docker_available || { err "Docker not available."; pause_enter; return 0; }

  local -a cs
  mapfile -t cs < <(list_docker_conduits_running)
  local c
  c="$(pick_from_list "Pick RUNNING docker container" "${cs[@]}")"
  [[ -z "${c}" ]] && return 0

  local action
  action="$(pick_from_list "Action for ${c}" "stop" "restart" "status")"
  [[ -z "${action}" ]] && return 0

  header
  printf "%sDocker Container Action%s\n\n" "${C_BOLD}" "${C_RESET}"
  printf "Container: %s\nAction:    %s\n\n" "$c" "$action"

  local out rc
  case "$action" in
    stop)    out="$(docker stop "$c" 2>&1)"; rc=$? ;;
    restart) out="$(docker restart "$c" 2>&1)"; rc=$? ;;
    status)  docker inspect "$c" --format 'Status={{.State.Status}}  StartedAt={{.State.StartedAt}}  Image={{.Config.Image}}'; pause_enter; return 0 ;;
    *) out="Unknown action"; rc=2 ;;
  esac

  if (( rc == 0 )); then ok "Action succeeded."; else err "Action failed (rc=${rc})."; fi
  [[ -n "$out" ]] && { printf "\nOutput:\n%s\n" "$out"; }
  pause_enter
}

docker_delete_instance() {
  need_root || return 0
  docker_available || { err "Docker not available."; pause_enter; return 0; }
  mkdir -p "${DOCKER_INSTANCES_DIR}" >/dev/null 2>&1 || true

  local -a cs
  mapfile -t cs < <(list_docker_conduits_all)
  local c
  c="$(pick_from_list "Pick docker container to DELETE (running or stopped)" "${cs[@]}")"
  [[ -z "${c}" ]] && return 0

  header
  warn "This will remove container. If it's a managed instance, it will also remove its volume + folder."
  printf "  - Container: %s\n\n" "$c"

  local confirm
  read -r -p "Type DELETE to confirm: " confirm </dev/tty || true
  [[ "${confirm:-}" != "DELETE" ]] && { ok "Canceled."; pause_enter; return 0; }

  # Try to map container name back to managed instance folder: conduit<NUM>
  local num=""
  if [[ "$c" =~ ^Conduit([0-9]+)\.docker$ ]]; then
    num="${BASH_REMATCH[1]}"
  elif [[ "$c" =~ ^conduit([0-9]+)$ ]]; then
    num="${BASH_REMATCH[1]}"
  fi

  local inst="" inst_dir="" conf=""
  if [[ -n "$num" ]]; then
    inst="conduit${num}"
    inst_dir="${DOCKER_INSTANCES_DIR}/${inst}"
    conf="${inst_dir}/instance.conf"
  fi

  # Remove container first
  docker rm -f "$c" 2>&1 || true

  # If managed config exists, also remove volume + folder
  if [[ -n "$conf" && -f "$conf" ]]; then
    docker_load_instance_conf "$conf" || true
    [[ -n "${VOLUME_NAME:-}" ]] && docker volume rm -f "$VOLUME_NAME" 2>&1 || true
    rm -rf "$inst_dir" >/dev/null 2>&1 || true
  fi

  ok "Deleted docker container: ${c}"
  pause_enter
}

docker_logs_last10() {
  docker_available || { err "Docker not available or daemon not running."; pause_enter; return 0; }

  local -a cs
  mapfile -t cs < <(list_docker_conduits_all)
  local c
  c="$(pick_from_list "Pick docker container (last log lines)" "${cs[@]}")"
  [[ -z "${c}" ]] && return 0

  header
  printf "%sLast %s log lines:%s %s\n\n" "${C_BOLD}" "${CFG_LOG_TAIL}" "${C_RESET}" "${c}"
  docker logs --tail "${CFG_LOG_TAIL}" "${c}" 2>/dev/null || true
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
# ------------------------- NIC sampler (htop-like, non-blocking) ----------------
NIC_CACHE_FILE="${RUN_ROOT}/nic.cache"
NIC_SAMPLER_PID=""

nic_cache_read() {
  # Output: rx_mbps|tx_mbps (may be empty if not ready)
  if [[ -r "${NIC_CACHE_FILE}" ]]; then
    local line
    line="$(cat "${NIC_CACHE_FILE}" 2>/dev/null || true)"
    [[ -n "$line" ]] && printf "%s" "$line"
  fi
}

nic_sampler_stop() {
  if [[ -n "${NIC_SAMPLER_PID:-}" ]] && kill -0 "${NIC_SAMPLER_PID}" 2>/dev/null; then
    kill "${NIC_SAMPLER_PID}" 2>/dev/null || true
    wait "${NIC_SAMPLER_PID}" 2>/dev/null || true
  fi
  NIC_SAMPLER_PID=""
}

nic_sampler_start() {
  # Runs in background, sampling NIC bytes and computing Mbps every 1s.
  # Uses /sys counters if available; falls back to /proc/net/dev.
  local ifc="$1"
  mkdir -p "${RUN_ROOT}" 2>/dev/null || true

  nic_sampler_stop

  (
    local prev_ts prev rx tx now dt_ns rxm txm
    prev_ts="$(date +%s%N 2>/dev/null || date +%s000000000)"
    now="$(read_iface_bytes "$ifc")"
    rx="${now%%|*}"; tx="${now##*|}"
    prev="$rx|$tx"

    # Warm-up: small sleep so first rate is not zero.
    sleep 0.2

    while true; do
      local ts
      ts="$(date +%s%N 2>/dev/null || date +%s000000000)"
      now="$(read_iface_bytes "$ifc")"
      rx="${now%%|*}"; tx="${now##*|}"

      dt_ns=$(( ts - prev_ts ))
      (( dt_ns < 1 )) && dt_ns=1

      # Mbps = (delta_bytes * 8) / 1e6 / dt_seconds
      # dt_seconds = dt_ns / 1e9  => Mbps = delta_bytes * 8 * 1e3 / dt_ns
      rxm="$(awk -v a="$rx" -v b="${prev%%|*}" -v d="$dt_ns" 'BEGIN{if(d<1)d=1; v=(a-b); if(v<0)v=0; printf "%.2f", (v*8*1000)/d }')"
      txm="$(awk -v a="$tx" -v b="${prev##*|}" -v d="$dt_ns" 'BEGIN{if(d<1)d=1; v=(a-b); if(v<0)v=0; printf "%.2f", (v*8*1000)/d }')"

      printf "%s|%s\n" "$rxm" "$txm" >"${NIC_CACHE_FILE}.tmp" 2>/dev/null || true
      mv -f "${NIC_CACHE_FILE}.tmp" "${NIC_CACHE_FILE}" 2>/dev/null || true

      prev="$rx|$tx"
      prev_ts="$ts"
      sleep 1
    done
  ) &
  NIC_SAMPLER_PID=$!
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
  local s num unit
  s="$(trim "${1:-0B}")"
  s="$(sed -E 's/([0-9]) +([A-Za-z])/\1\2/g' <<<"$s")"
  num="$(sed -E 's/^([0-9]+(\.[0-9]+)?).*/\1/' <<<"$s")"
  unit="$(sed -E 's/^[0-9]+(\.[0-9]+)?([A-Za-z]+).*/\2/' <<<"$s")"
  [[ -z "$num" ]] && num="0"
  [[ -z "$unit" ]] && unit="B"
  unit="$(tr '[:lower:]' '[:upper:]' <<<"$unit")"
  case "$unit" in
    B)   awk -v n="$num" 'BEGIN{printf "%.0f", n}' ;;
    KB)  awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}' ;;
    MB)  awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}' ;;
    GB)  awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}' ;;
    TB)  awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}' ;;
    *)   awk -v n="$num" 'BEGIN{printf "%.0f", n}' ;;
  esac
}

bytes_to_human_nospace() {
  local b="${1:-0}"
  [[ -z "$b" ]] && b=0
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  if (( b < 1024 )); then echo "${b}B"; return; fi
  if (( b < 1024*1024 )); then awk -v b="$b" 'BEGIN{printf "%.1fKB", b/1024}'; return; fi
  if (( b < 1024*1024*1024 )); then awk -v b="$b" 'BEGIN{printf "%.1fMB", b/1024/1024}'; return; fi
  if (( b < 1024*1024*1024*1024 )); then awk -v b="$b" 'BEGIN{printf "%.1fGB", b/1024/1024/1024}'; return; fi
  awk -v b="$b" 'BEGIN{printf "%.1fTB", b/1024/1024/1024/1024}'
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
nic_summary() {
  local iface="$1" rx="$2" tx="$3"
  printf "📡 NIC:%s RX:%sMbps TX:%sMbps" "$iface" "$rx" "$tx"
}

print_nic_box() {
  local iface="$1" rx="$2" tx="$3"
  local cols inner
  cols="$(ui_cols)"
  inner=$((cols-2))
  (( inner < 40 )) && inner=40

  local top bottom
  top="+$(repeat_char "$inner" "-")+"
  bottom="+$(repeat_char "$inner" "-")+"

  local content clen pad
  content="📡 NIC: ${iface}    RX: ${rx} Mbps    TX: ${tx} Mbps"
  clen=${#content}
  pad=$((inner - clen))
  (( pad < 0 )) && pad=0

  printf "%s%s%s\n" "${C_CYAN}" "$top" "${C_RESET}"
  printf "%s|%s%s%s|%s\n" "${C_CYAN}" "${C_RESET}" "$content" "$(repeat_char "$pad" " ")" "${C_RESET}"
  printf "%s%s%s\n" "${C_CYAN}" "$bottom" "${C_RESET}"
}

print_dash_header() {
  local cols namew
  cols="$(ui_cols)"
  namew="$(dash_name_width "$cols")"

  # Width profile to keep tail columns visible under width caps (-b).
  local w_conn=11 w_cted=10 w_up=10 w_down=10 w_upt=11 w_m=5 w_b=5
  if (( cols < 100 )); then
    w_conn=8; w_cted=8; w_up=9; w_down=9; w_upt=10; w_m=5; w_b=5
  fi
  if (( cols < 86 )); then
    w_conn=6; w_cted=6; w_up=8; w_down=8; w_upt=9; w_m=4; w_b=4
  fi

  printf "%-6s %-${namew}s %3s %${w_conn}s %${w_cted}s %${w_up}s %${w_down}s %${w_upt}s %${w_m}s %${w_b}s
"     "TYPE" "NAME" "ST" "Connecting" "Connected" "Up" "Down" "Uptime" "-m" "-b"

  printf "%s
" "$(repeat_char "$cols" "-")"
}

print_dash_row() {
  local type="$1" name="$2" st="$3" connecting="$4" connected="$5" up="$6" down="$7" uptime="$8" m="$9" b="${10}"
  local cols namew
  cols="$(ui_cols)"
  namew="$(dash_name_width "$cols")"

  local w_conn=11 w_cted=10 w_up=10 w_down=10 w_upt=11 w_m=5 w_b=5
  if (( cols < 100 )); then
    w_conn=8; w_cted=8; w_up=9; w_down=9; w_upt=10; w_m=5; w_b=5
  fi
  if (( cols < 86 )); then
    w_conn=6; w_cted=6; w_up=8; w_down=8; w_upt=9; w_m=4; w_b=4
  fi

  printf "%-6s %-${namew}.${namew}s %3s %${w_conn}s %${w_cted}s %${w_up}s %${w_down}s %${w_upt}s %${w_m}s %${w_b}s
"     "$type" "$name" "$st" "$connecting" "$connected" "$up" "$down" "$uptime" "$m" "$b"
}


render_compare_bar() {
  # label, docker_value, native_value, total, cols, barw_fixed, docker_pretty, native_pretty, total_pretty
  local label="$1" dval="$2" nval="$3" total="$4" cols="$5" barw="$6"
  local dpretty="${7:-$dval}" npretty="${8:-$nval}" tpretty="${9:-$total}"

  # Enforce identical bar size for every metric.
  (( barw < 10 )) && barw=10
  (( barw > 80 )) && barw=80

  # Compute segment lengths.
  local dlen=0 nlen=0
  if (( total > 0 )); then
    dlen=$(( dval * barw / total ))
    (( dlen < 0 )) && dlen=0
    (( dlen > barw )) && dlen=$barw
    nlen=$(( nval * barw / total ))
    (( nlen < 0 )) && nlen=0
    (( dlen + nlen > barw )) && nlen=$(( barw - dlen ))
  fi
  local empty=$(( barw - dlen - nlen ))
  (( empty < 0 )) && empty=0

  # Bar uses only '|'. Empty space is blank.
  local bar=""
  bar+="${C_ROW_DOCKER}$(repeat_char "$dlen" '|')${C_RESET}"
  bar+="${C_ROW_NATIVE}$(repeat_char "$nlen" '|')${C_RESET}"
  bar+="$(repeat_char "$empty" ' ')"

  # Numbers should be BEFORE the bar for readability.
  local nums="${C_ROW_DOCKER}D:${dpretty}/${tpretty}${C_RESET} ${C_ROW_NATIVE}N:${npretty}/${tpretty}${C_RESET}"

  local labelw=7
  local prefix
  prefix="$(printf '%-*s ' "$labelw" "$label")"

  # Single line: LABEL + NUMS + BAR (clamped by -b via sanitize_line).
  local line="${prefix}${nums}  ${bar}"
  printf "%s\n" "$(sanitize_line "$line")"
}


print_totals_compare() {
  local d_count="$1" n_count="$2"
  local d_conn="$3" n_conn="$4"
  local d_connected="$5" n_connected="$6"
  local d_upb="$7" n_upb="$8"
  local d_downb="$9" n_downb="${10}"

  local cols inner
  cols="$(ui_cols)"
  inner=$((cols-2))
  (( inner < 40 )) && inner=40

  local top bottom
  top="+$(repeat_char "$inner" "-")+"
  bottom="+$(repeat_char "$inner" "-")+"

  local all=$((d_count + n_count))

  printf "%s%s%s\n" "${C_CYAN}" "$top" "${C_RESET}"
  local line="TOTAL: Docker=${d_count} | Native=${n_count} | All=${all}"
  local pad=$((inner - ${#line}))
  (( pad < 0 )) && pad=0
  printf "%s|%s%s%s|%s\n" "${C_CYAN}" "${C_RESET}" "$line" "$(repeat_char "$pad" " ")" "${C_RESET}"

  printf "%s\n" "$(repeat_char "$cols" "-")"

  local t_conn=$((d_conn + n_conn))
  local t_connected=$((d_connected + n_connected))
  local t_upb=$((d_upb + n_upb))
  local t_downb=$((d_downb + n_downb))

  # Fixed bar width for ALL metrics so every bar is visually identical.
  local barw_fixed=$(( cols - 40 ))
  (( barw_fixed < 20 )) && barw_fixed=20
  (( barw_fixed > 60 )) && barw_fixed=60

  render_compare_bar "Connecting" "$d_conn" "$n_conn" "$t_conn" "$cols" "$barw_fixed" "$d_conn" "$n_conn" "$t_conn"
  render_compare_bar "Connected"  "$d_connected" "$n_connected" "$t_connected" "$cols" "$barw_fixed" "$d_connected" "$n_connected" "$t_connected"

  printf "%s\n" "$(repeat_char "$cols" "-")"

  local d_up_h n_up_h t_up_h d_down_h n_down_h t_down_h
  d_up_h="$(bytes_to_human_nospace "$d_upb")"
  n_up_h="$(bytes_to_human_nospace "$n_upb")"
  t_up_h="$(bytes_to_human_nospace "$t_upb")"
  d_down_h="$(bytes_to_human_nospace "$d_downb")"
  n_down_h="$(bytes_to_human_nospace "$n_downb")"
  t_down_h="$(bytes_to_human_nospace "$t_downb")"

  render_compare_bar "Up"   "$d_upb"   "$n_upb"   "$t_upb"   "$cols" "$barw_fixed" "$d_up_h"   "$n_up_h"   "$t_up_h"
  render_compare_bar "Down" "$d_downb" "$n_downb" "$t_downb" "$cols" "$barw_fixed" "$d_down_h" "$n_down_h" "$t_down_h"

  printf "%s%s%s\n" "${C_CYAN}" "$bottom" "${C_RESET}"
}

print_totals_box() {
  local services="$1" okc="$2" waitc="$3" errc="$4" tconn="$5" tconnected="$6" tup="$7" tdown="$8"

  local cols inner
  cols="$(ui_cols)"
  inner=$((cols-2))
  (( inner < 40 )) && inner=40

  local top bottom
  top="+$(repeat_char "$inner" "-")+"
  bottom="+$(repeat_char "$inner" "-")+"

  local l1 l2 pad
  l1="📊 TOTAL: Services=${services} | ✅ OK=${okc} | ⏳ WAIT=${waitc} | 🔴 ERR/DOWN=${errc}"
  pad=$((inner - ${#l1})); (( pad < 0 )) && pad=0
  printf "
%s%s%s\n" "${C_CYAN}" "$top" "${C_RESET}"
  printf "%s|%s%s%s|%s\n" "${C_CYAN}" "${C_RESET}" "$l1" "$(repeat_char "$pad" " ")" "${C_RESET}"

  l2="🔌 Connecting=${tconn} | 🟢 Connected=${tconnected} | ⬆️ Up=${tup} | ⬇️ Down=${tdown}"
  pad=$((inner - ${#l2})); (( pad < 0 )) && pad=0
  printf "%s|%s%s%s|%s\n" "${C_CYAN}" "${C_RESET}" "$l2" "$(repeat_char "$pad" " ")" "${C_RESET}"
  printf "%s%s%s\n" "${C_CYAN}" "$bottom" "${C_RESET}"
}


print_legend_end() {
  local refresh="$1" iface="$2"
  local left right
  left="Legend: ${C_RED}●${C_RESET} error/down  ${C_YELLOW}●${C_RESET} waiting  ${C_GREEN}●${C_RESET} active"
  right="Live Dashboard (refresh=${refresh}s, iface=${iface})"
  print_lr_line "$left" "$right"
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

unit_state_short() {
  # Compact 3-char status for table column.
  local s="${1:-}"
  case "$s" in
    active|running) echo "OK" ;;
    activating|reloading|start*) echo "WAI" ;;
    exited|inactive|dead) echo "OFF" ;;
    failed) echo "ERR" ;;
    *) echo "---" ;;
  esac
}

docker_state_short() {
  local s="${1:-}"
  case "$s" in
    running) echo "OK" ;;
    exited|created) echo "OFF" ;;
    restarting|paused) echo "WAI" ;;
    dead) echo "ERR" ;;
    *) echo "---" ;;
  esac
}


status_color_short() {
  # Map compact status to Legend colors.
  local st="${1:-}"
  case "$st" in
    OK)  printf "%s" "${C_LEG_ACTIVE}" ;;
    WAI) printf "%s" "${C_LEG_IDLE}" ;;
    OFF) printf "%s" "${C_LEG_DOWN}" ;;
    ERR) printf "%s" "${C_LEG_DOWN}" ;;
    *)   printf "%s" "${C_DIM}" ;;
  esac
}

dashboard_row_line() {
  # Build a single table row with correct alignment while allowing per-field colors.
  local type="$1" name="$2" st="$3" connecting="$4" connected="$5" up="$6" down="$7" uptime="$8" m="$9" b="${10}"
  local cols namew
  cols="$(ui_cols)"
  namew="$(dash_name_width "$cols")"

  # Width profile (must match print_dash_header/print_dash_row).
  local w_conn=11 w_cted=10 w_up=10 w_down=10 w_upt=11 w_m=5 w_b=5
  if (( cols < 100 )); then
    w_conn=8; w_cted=8; w_up=9; w_down=9; w_upt=10; w_m=5; w_b=5
  fi
  if (( cols < 86 )); then
    w_conn=6; w_cted=6; w_up=8; w_down=8; w_upt=9; w_m=4; w_b=4
  fi

  local base="${C_RESET}"
  case "$type" in
    NATIVE) base="${C_ROW_NATIVE}" ;;
    DOCK|DOCKER) base="${C_ROW_DOCKER}" ;;
    *) base="${C_RESET}" ;;
  esac

  local stc; stc="$(status_color_short "$st")"

  local out=""
  printf -v out "%s%-6s%s %s%-${namew}.${namew}s%s %s%3s%s" \
    "$base" "$type" "$C_RESET" \
    "$base" "$name" "$C_RESET" \
    "$stc" "$st" "$C_RESET"

  local part=""
  printf -v part " %s%${w_conn}s%s %s%${w_cted}s%s %s%${w_up}s%s %s%${w_down}s%s %s%${w_upt}s%s %s%${w_m}s%s %s%${w_b}s%s" \
    "$base" "$connecting" "$C_RESET" \
    "$base" "$connected" "$C_RESET" \
    "$base" "$up" "$C_RESET" \
    "$base" "$down" "$C_RESET" \
    "$base" "$uptime" "$C_RESET" \
    "$base" "$m" "$C_RESET" \
    "$base" "$b" "$C_RESET"

  printf "%s%s" "$out" "$part"
}


# ------------------------- Parallel snapshot helpers ---------------------------
waitn_supported() {
  # Returns 0 if "wait -n" is supported by current bash.
  ( wait -n 2>/dev/null ) && return 0
  return 1
}

PAR_LIMIT=0
PAR_PIDS=()

par_reset() {
  PAR_LIMIT="${1:-10}"
  PAR_PIDS=()
}

par_spawn() {
  # Usage: par_spawn <cmd...>
  # Runs command in background with semaphore limit PAR_LIMIT.
  "$@" &
  local pid=$!
  PAR_PIDS+=("$pid")
  if (( ${#PAR_PIDS[@]} >= PAR_LIMIT )); then
    par_wait_one
  fi
}

par_wait_one() {
  # Wait for one job to finish.
  if waitn_supported; then
    wait -n 2>/dev/null || true
  else
    # Fallback: wait first pid.
    local pid="${PAR_PIDS[0]:-}"
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null || true
  fi
  # Prune finished pids.
  local -a alive=()
  local p
  for p in "${PAR_PIDS[@]}"; do
    if kill -0 "$p" 2>/dev/null; then
      alive+=("$p")
    else
      wait "$p" 2>/dev/null || true
    fi
  done
  PAR_PIDS=("${alive[@]}")
}

par_wait_all() {
  local p
  for p in "${PAR_PIDS[@]}"; do
    wait "$p" 2>/dev/null || true
  done
  PAR_PIDS=()
}

dash_collect_native_one() {
  # idx, unit, tmpdir
  local idx="$1" u="$2" tmpdir="$3"
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
    connecting="0"; connected="0"; up="0B"; down="0B"; uptime="-"
  fi

  [[ "$connecting" =~ ^[0-9]+$ ]] || connecting=0
  [[ "$connected"  =~ ^[0-9]+$ ]] || connected=0

  local upb downb
  upb="$(human_to_bytes "$up" 2>/dev/null || echo 0)"
  downb="$(human_to_bytes "$down" 2>/dev/null || echo 0)"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s
' \
    "NATIVE" "$u" "$(unit_state_short "$st")" "$connecting" "$connected" "$upb" "$downb" "$uptime" "$m" "$b" \
    >"${tmpdir}/n.${idx}" 2>/dev/null || true
}

dash_collect_docker_one() {
  # idx, container_name, tmpdir
  local idx="$1" name="$2" tmpdir="$3"
  local st m b stats parsed connecting connected up down uptime
  st="$(docker_state "$name")"

  read -r m b < <(docker_get_m_b_inspect "$name")
  if [[ "$m" == "-" || "$b" == "-" ]]; then
    local fm fb
    read -r fm fb < <(docker_get_m_b_from_conf "$name")
    [[ "$m" == "-" ]] && m="$fm"
    [[ "$b" == "-" ]] && b="$fb"
  fi
  b="$(bw_pretty "$b")"

  stats="$(last_stats_docker "$name")"
  if [[ -n "$stats" ]]; then
    parsed="$(parse_stats_line "$stats")"
    connecting="${parsed%%|*}"; parsed="${parsed#*|}"
    connected="${parsed%%|*}"; parsed="${parsed#*|}"
    up="${parsed%%|*}"; parsed="${parsed#*|}"
    down="${parsed%%|*}"; uptime="${parsed##*|}"
  else
    connecting="0"; connected="0"; up="0B"; down="0B"; uptime="-"
  fi

  [[ "$connecting" =~ ^[0-9]+$ ]] || connecting=0
  [[ "$connected"  =~ ^[0-9]+$ ]] || connected=0

  local upb downb
  upb="$(human_to_bytes "$up" 2>/dev/null || echo 0)"
  downb="$(human_to_bytes "$down" 2>/dev/null || echo 0)"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s
' \
    "DOCK" "$name" "$(docker_state_short "$st")" "$connecting" "$connected" "$upb" "$downb" "$uptime" "$m" "$b" \
    >"${tmpdir}/d.${idx}" 2>/dev/null || true
}


dashboard_snapshot() {
  # Collect a full snapshot into DASH_* globals.
  # This function runs inside a background worker; therefore it MUST be stateless.
  local view="${1:-ALL}"     # ALL|DOCKER|NATIVE
  local compact="${2:-0}"    # 1 -> totals-only (no per-instance rows)

  DASH_IFACE="$(default_iface)"
  [[ -n "${CFG_NET_IFACE:-}" ]] && DASH_IFACE="${CFG_NET_IFACE}"

  # NIC Mbps: read from sampler cache (worker-safe).
  local nic
  nic="$(nic_cache_read || true)"
  if [[ -n "$nic" && "$nic" == *"|"* ]]; then
    DASH_RX_MBPS="${nic%%|*}"
    DASH_TX_MBPS="${nic##*|}"
  else
    DASH_RX_MBPS="0.00"
    DASH_TX_MBPS="0.00"
  fi

  # Memory snapshot
  local mem; mem="$(mem_usage_bytes)"
  DASH_MEM_USED="${mem%%|*}"; mem="${mem#*|}"
  DASH_MEM_TOTAL="${mem%%|*}"

  # Totals
  DASH_NATIVE_COUNT=0; DASH_DOCKER_COUNT=0
  DASH_N_CONN=0; DASH_N_CONNECTED=0; DASH_N_UPB=0; DASH_N_DOWNB=0
  DASH_D_CONN=0; DASH_D_CONNECTED=0; DASH_D_UPB=0; DASH_D_DOWNB=0

  DASH_ROWS=()

  # Collect lists once (fast)
  local -a units dockers
  mapfile -t units < <(list_native_loaded_units)
  mapfile -t dockers < <(list_docker_conduits_running)

  # Counts are authoritative from lists (even if a collector fails).
  local u name
  for u in "${units[@]}"; do [[ -n "$u" ]] && DASH_NATIVE_COUNT=$((DASH_NATIVE_COUNT+1)); done
  for name in "${dockers[@]}"; do [[ -n "$name" ]] && DASH_DOCKER_COUNT=$((DASH_DOCKER_COUNT+1)); done

  # Parallel collectors (bounded). Each job writes one small line to tmpdir.
  mkdir -p "${RUN_ROOT}" 2>/dev/null || true
  local tmpdir
  tmpdir="$(mktemp -d "${RUN_ROOT}/snap.XXXXXX" 2>/dev/null || mktemp -d)"

  local max_jobs="${CFG_MAX_JOBS:-12}"
  [[ "$max_jobs" =~ ^[0-9]+$ ]] || max_jobs=12
  (( max_jobs < 2 )) && max_jobs=2
  (( max_jobs > 40 )) && max_jobs=40

  # Native collectors
  par_reset "$max_jobs"
  local idx=0
  for u in "${units[@]}"; do
    [[ -z "$u" ]] && continue
    par_spawn dash_collect_native_one "$idx" "$u" "$tmpdir"
    idx=$((idx+1))
  done
  par_wait_all

  # Docker collectors
  par_reset "$max_jobs"
  idx=0
  for name in "${dockers[@]}"; do
    [[ -z "$name" ]] && continue
    par_spawn dash_collect_docker_one "$idx" "$name" "$tmpdir"
    idx=$((idx+1))
  done
  par_wait_all

  # Aggregate in stable order: native first, then docker (as before).
  local file type stshort connecting connected upb downb uptime m b

  idx=0
  for u in "${units[@]}"; do
    [[ -z "$u" ]] && continue
    file="${tmpdir}/n.${idx}"
    if [[ -r "$file" ]]; then
      IFS='|' read -r type name stshort connecting connected upb downb uptime m b <"$file" 2>/dev/null || true
    else
      type="NATIVE"; name="$u"; stshort="OFF"; connecting=0; connected=0; upb=0; downb=0; uptime="-"; m="-"; b="-"
    fi

    [[ "$connecting" =~ ^[0-9]+$ ]] || connecting=0
    [[ "$connected"  =~ ^[0-9]+$ ]] || connected=0
    [[ "$upb"        =~ ^[0-9]+$ ]] || upb=0
    [[ "$downb"      =~ ^[0-9]+$ ]] || downb=0

    DASH_N_CONN=$((DASH_N_CONN + connecting))
    DASH_N_CONNECTED=$((DASH_N_CONNECTED + connected))
    DASH_N_UPB=$((DASH_N_UPB + upb))
    DASH_N_DOWNB=$((DASH_N_DOWNB + downb))

    if [[ "$compact" != "1" && ( "$view" == "ALL" || "$view" == "NATIVE" ) ]]; then
      local line
      line="$(dashboard_row_line "NATIVE" "$name" "$stshort" "$connecting" "$connected" "$(bytes_to_human_nospace "$upb")" "$(bytes_to_human_nospace "$downb")" "$uptime" "$m" "$b")"
      DASH_ROWS+=("$(sanitize_line "$line")")
    fi

    idx=$((idx+1))
  done

  idx=0
  for name in "${dockers[@]}"; do
    [[ -z "$name" ]] && continue
    file="${tmpdir}/d.${idx}"
    if [[ -r "$file" ]]; then
      IFS='|' read -r type u stshort connecting connected upb downb uptime m b <"$file" 2>/dev/null || true
      # Re-map: u contains name
      name="$u"
    else
      type="DOCK"; stshort="OFF"; connecting=0; connected=0; upb=0; downb=0; uptime="-"; m="-"; b="-"
    fi

    [[ "$connecting" =~ ^[0-9]+$ ]] || connecting=0
    [[ "$connected"  =~ ^[0-9]+$ ]] || connected=0
    [[ "$upb"        =~ ^[0-9]+$ ]] || upb=0
    [[ "$downb"      =~ ^[0-9]+$ ]] || downb=0

    DASH_D_CONN=$((DASH_D_CONN + connecting))
    DASH_D_CONNECTED=$((DASH_D_CONNECTED + connected))
    DASH_D_UPB=$((DASH_D_UPB + upb))
    DASH_D_DOWNB=$((DASH_D_DOWNB + downb))

    if [[ "$compact" != "1" && ( "$view" == "ALL" || "$view" == "DOCKER" ) ]]; then
      local line
      line="$(dashboard_row_line "DOCK" "$name" "$stshort" "$connecting" "$connected" "$(bytes_to_human_nospace "$upb")" "$(bytes_to_human_nospace "$downb")" "$uptime" "$m" "$b")"
      DASH_ROWS+=("$(sanitize_line "$line")")
    fi

    idx=$((idx+1))
  done

  rm -rf "$tmpdir" 2>/dev/null || true
}


dashboard_render() {
  local view="${1:-ALL}" compact="${2:-0}" paused="${3:-0}"

  local cols; cols="$(ui_cols)"
  printf "\033[H\033[2J"   # clear screen, cursor home (htop style)

  # Header: Legend left, Live Dashboard status right
  local legend status
  legend="Legend: ${C_LEG_DOWN}*${C_RESET} down  ${C_LEG_IDLE}*${C_RESET} idle  ${C_LEG_ACTIVE}*${C_RESET} active"
  status="Live Dashboard (refresh=${CFG_REFRESH_SECS}s, iface=${DASH_IFACE})"
  print_lr_line "$legend" "$status"

  # NIC + MEM line (colored segments)
  local nic_line mem_line
  mem_line="$(format_mem_line "$DASH_MEM_USED" "$DASH_MEM_TOTAL")"
  nic_line="${C_NIC_LBL_CLR}NIC:${C_RESET} ${C_WHITE}${DASH_IFACE}${C_RESET}  ${C_NIC_RX_CLR}RX${C_RESET}=${C_NIC_RX_CLR}${DASH_RX_MBPS}Mbps${C_RESET}  ${C_NIC_TX_CLR}TX${C_RESET}=${C_NIC_TX_CLR}${DASH_TX_MBPS}Mbps${C_RESET}"
  print_lr_line "$nic_line" "${C_DIM}${mem_line}${C_RESET}"

  printf "%s\n" "$(repeat_char "$cols" "-")"

  # Totals + compare bars (htop style)
  local all=$((DASH_DOCKER_COUNT + DASH_NATIVE_COUNT))
  local totals_line="TOTAL  ${C_ROW_DOCKER}Docker=${DASH_DOCKER_COUNT}${C_RESET}  ${C_ROW_NATIVE}Native=${DASH_NATIVE_COUNT}${C_RESET}  All=${all}"
  printf "%s\n" "$(sanitize_line "$totals_line")"

  local barw_fixed=$(( cols - 40 ))
  (( barw_fixed < 20 )) && barw_fixed=20
  (( barw_fixed > 60 )) && barw_fixed=60

  local t_conn=$((DASH_D_CONN + DASH_N_CONN))
  local t_connected=$((DASH_D_CONNECTED + DASH_N_CONNECTED))
  local t_upb=$((DASH_D_UPB + DASH_N_UPB))
  local t_downb=$((DASH_D_DOWNB + DASH_N_DOWNB))

  render_compare_bar "CONNECT" "$DASH_D_CONN" "$DASH_N_CONN" "$t_conn" "$cols" "$barw_fixed" "$DASH_D_CONN" "$DASH_N_CONN" "$t_conn"
  render_compare_bar "CONNED"  "$DASH_D_CONNECTED" "$DASH_N_CONNECTED" "$t_connected" "$cols" "$barw_fixed" "$DASH_D_CONNECTED" "$DASH_N_CONNECTED" "$t_connected"

  local d_up_h n_up_h t_up_h d_down_h n_down_h t_down_h
  d_up_h="$(bytes_to_human_nospace "$DASH_D_UPB")"
  n_up_h="$(bytes_to_human_nospace "$DASH_N_UPB")"
  t_up_h="$(bytes_to_human_nospace "$t_upb")"
  d_down_h="$(bytes_to_human_nospace "$DASH_D_DOWNB")"
  n_down_h="$(bytes_to_human_nospace "$DASH_N_DOWNB")"
  t_down_h="$(bytes_to_human_nospace "$t_downb")"

  render_compare_bar "UP"   "$DASH_D_UPB"   "$DASH_N_UPB"   "$t_upb"   "$cols" "$barw_fixed" "$d_up_h"   "$n_up_h"   "$t_up_h"
  render_compare_bar "DOWN" "$DASH_D_DOWNB" "$DASH_N_DOWNB" "$t_downb" "$cols" "$barw_fixed" "$d_down_h" "$n_down_h" "$t_down_h"

  if [[ "$compact" != "1" ]]; then
    printf "%s\n" "$(repeat_char "$cols" "-")"
    # Table header (uncolored; coloring is per-row wrapper).
    print_dash_header
    local row
    for row in "${DASH_ROWS[@]}"; do
      # Rows are already width-governed by dash column widths + ui_cols.
      printf "%s
" "$(sanitize_line "$row")"
    done
  fi

  # Bottom menu bar (htop style)
  bottom_menu_bar "$view" "$paused" "$compact"
}


dashboard_render_loading() {
  local view="${1:-ALL}" compact="${2:-0}" paused="${3:-0}"
  local cols; cols="$(ui_cols)"
  printf "[H[2J"

  local legend status
  legend="Legend: ${C_LEG_DOWN}*${C_RESET} down  ${C_LEG_IDLE}*${C_RESET} idle  ${C_LEG_ACTIVE}*${C_RESET} active"
  status="Live Dashboard (refresh=${CFG_REFRESH_SECS}s, iface=${CFG_NET_IFACE})"
  print_lr_line "$legend" "$status"

  local nic_line mem_line
  mem_line="MEM -/- (-%)"
  nic_line="${C_NIC_LBL_CLR}NIC:${C_RESET} ${C_WHITE}${CFG_NET_IFACE}${C_RESET}  ${C_NIC_RX_CLR}RX${C_RESET}=${C_NIC_RX_CLR}-${C_RESET}  ${C_NIC_TX_CLR}TX${C_RESET}=${C_NIC_TX_CLR}-${C_RESET}"
  print_lr_line "$nic_line" "${C_DIM}${mem_line}${C_RESET}"

  printf "%s\n" "$(repeat_char "$cols" "-")"
  printf "%s\n" "$(sanitize_line "${C_LEG_DOWN}${C_BLINK}Loading snapshot...${C_RESET}")"
  printf "%s\n" "$(repeat_char "$cols" "-")"
  bottom_menu_bar "$view" "$paused" "$compact"
}

dash_frame_init() {
  mkdir -p "$RUN_ROOT" 2>/dev/null || true
  DASH_FRAME_FILE="${RUN_ROOT}/dashboard.frame"
  DASH_FRAME_GEN_FILE="${RUN_ROOT}/dashboard.gen"
  DASH_FRAME_DONE_FILE="${RUN_ROOT}/dashboard.done"
  DASH_FRAME_LAST_SHOWN=""
  DASH_WORKER_PID=""
}

dash_worker_kill() {
  if [[ -n "${DASH_WORKER_PID:-}" ]] && kill -0 "$DASH_WORKER_PID" 2>/dev/null; then
    kill "$DASH_WORKER_PID" 2>/dev/null || true
    wait "$DASH_WORKER_PID" 2>/dev/null || true
  fi
  DASH_WORKER_PID=""
}

dash_worker_start() {
  local view="$1" compact="$2"
  dash_frame_init
  local gen
  gen="$(date +%s%N 2>/dev/null || date +%s)"
  echo "$gen" >"$DASH_FRAME_GEN_FILE" 2>/dev/null || true

  local tmp="${DASH_FRAME_FILE}.tmp.${gen}"

  dash_worker_kill

  (
    dashboard_snapshot "$view" "$compact"
    dashboard_render "$view" "$compact" 0
  ) >"$tmp" 2>/dev/null

  # Move into place and mark done (best-effort)
  mv -f "$tmp" "$DASH_FRAME_FILE" 2>/dev/null || true
  echo "$gen" >"$DASH_FRAME_DONE_FILE" 2>/dev/null || true
} 

dash_worker_start_bg() {
  local view="$1" compact="$2"
  # Start in background without blocking key handling.
  dash_worker_kill
  dash_worker_start "$view" "$compact" &
  DASH_WORKER_PID=$!
}

dash_maybe_display_frame() {
  local paused="$1"
  if [[ "$paused" == "1" ]]; then
    return 0
  fi
  if [[ -f "$DASH_FRAME_DONE_FILE" && -f "$DASH_FRAME_FILE" ]]; then
    local gen
    gen="$(cat "$DASH_FRAME_DONE_FILE" 2>/dev/null || true)"
    if [[ -n "$gen" && "$gen" != "$DASH_FRAME_LAST_SHOWN" ]]; then
      cat "$DASH_FRAME_FILE" >/dev/tty 2>/dev/null || true
      DASH_FRAME_LAST_SHOWN="$gen"
    fi
  fi
}

dashboard_loop() {
  local paused=0
  local compact=0
  local view="ALL"   # ALL|DOCKER|NATIVE

  term_enter_alt
  nic_sampler_start "${CFG_NET_IFACE:-$(default_iface)}"
  trap 'dash_worker_kill; nic_sampler_stop; term_exit_alt; printf "
"; return 0' INT TERM

  dash_frame_init
  dashboard_render_loading "$view" "$compact" "$paused"

  # Kick first frame build immediately (background).
  dash_worker_start_bg "$view" "$compact"
  local next_tick=$((SECONDS + CFG_REFRESH_SECS))

  while true; do
    # Show fresh frame if ready (fast path)
    dash_maybe_display_frame "$paused"

    # Key handling (never blocked by snapshot/render)
    local key
    key="$(read_key)"
    case "$key" in
      F10)
        dash_worker_kill
        nic_sampler_stop
        term_exit_alt
        return 0
        ;;
      F8)
        if [[ "$paused" == "1" ]]; then paused=0; else paused=1; fi
        # If unpausing, immediately paint latest frame if present
        dash_maybe_display_frame "$paused"
        ;;
      F12)
        if [[ "$compact" == "1" ]]; then compact=0; else compact=1; fi
        dashboard_render_loading "$view" "$compact" "$paused"
        dash_worker_start_bg "$view" "$compact"
        ;;
      F9)
        case "$view" in
          ALL) view="DOCKER" ;;
          DOCKER) view="NATIVE" ;;
          NATIVE) view="ALL" ;;
          *) view="ALL" ;;
        esac
        dashboard_render_loading "$view" "$compact" "$paused"
        dash_worker_start_bg "$view" "$compact"
        ;;
      *) ;;
    esac

    # Scheduled refresh (data is collected even when paused; UI stays frozen)
    if (( SECONDS >= next_tick )); then
      # Do not stack workers: if one is running, let it finish.
      if [[ -z "${DASH_WORKER_PID:-}" ]] || ! kill -0 "$DASH_WORKER_PID" 2>/dev/null; then
        dash_worker_start_bg "$view" "$compact"
      fi
      next_tick=$((SECONDS + CFG_REFRESH_SECS))
    fi

    sleep 0.03
  done
}

# ------------------------- Settings Menu ---------------------------------------
settings_network_menu() {
  while true; do
    header
    printf "%sSettings → Network%s\n\n" "${C_BOLD}" "${C_RESET}"
    printf "Current iface: %s\n\n" "${CFG_NET_IFACE}"
echo "1) Select network interface"
echo "2) Show NAT POSTROUTING rules (load-balancing status)"
echo "3) Run Load Balancer Wizard (lb-wizard.sh)"
echo "4) Quick network check (ping/DNS/curl) [delegated to Health script]"
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
        header
        printf "%sSettings → Network → NAT POSTROUTING%s\n\n" "${C_BOLD}" "${C_RESET}"
        if cmd_exists iptables; then
          iptables -t nat -L POSTROUTING -n -v --line-numbers 2>/dev/null || true
        else
          warn "iptables not found."
        fi
        pause_enter
        ;;
      3)
        header
        printf "%sSettings → Network → Load Balancer Wizard%s\n\n" "${C_BOLD}" "${C_RESET}"
        local lbw=""
        if [[ -x "${SCRIPT_DIR}/lb-wizard.sh" ]]; then
          lbw="${SCRIPT_DIR}/lb-wizard.sh"
        elif [[ -x "/usr/local/sbin/lb-wizard.sh" ]]; then
          lbw="/usr/local/sbin/lb-wizard.sh"
        elif command -v lb-wizard.sh >/dev/null 2>&1; then
          lbw="$(command -v lb-wizard.sh)"
        fi
        if [[ -n "$lbw" ]]; then
          "$lbw" || true
          config_load; init_colors
        else
          warn "lb-wizard.sh not found (expected in ${SCRIPT_DIR} or /usr/local/sbin)."
          pause_enter
        fi
        ;;

      4)
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
    printf "Refresh seconds     : %s\n" "${CFG_REFRESH_SECS}"
    printf "Log tail lines      : %s\n" "${CFG_LOG_TAIL}"
    printf "Max parallel jobs   : %s\n" "${CFG_MAX_JOBS:-$CFG_MAX_JOBS_DEFAULT}"
    printf "Color output        : %s\n\n" "${CFG_COLOR}"

    echo "1) Set refresh seconds"
    echo "2) Set log tail lines"
    echo "3) Set max parallel jobs (snapshot concurrency)"
    echo "4) Toggle colors"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1)
        local v
        read -r -p "New refresh seconds (1..300): " v </dev/tty || true
        [[ "${v:-}" =~ ^[0-9]+$ ]] || { warn "Invalid number"; continue; }
        (( v < 1 || v > 300 )) && { warn "Out of range"; continue; }
        CFG_REFRESH_SECS="$v"
        config_save_console_refresh "$v" || true
        ;;
      2)
        local v
        read -r -p "New log tail lines (10..2000): " v </dev/tty || true
        [[ "${v:-}" =~ ^[0-9]+$ ]] || { warn "Invalid number"; continue; }
        (( v < 10 || v > 2000 )) && { warn "Out of range"; continue; }
        CFG_LOG_TAIL="$v"
        config_save_console_logtail "$v" || true
        ;;
      3)
        local v
        read -r -p "Max parallel jobs (2..40): " v </dev/tty || true
        [[ "${v:-}" =~ ^[0-9]+$ ]] || { warn "Invalid number"; continue; }
        (( v < 2 || v > 40 )) && { warn "Out of range"; continue; }
        CFG_MAX_JOBS="$v"
        cfg_save_kv || true
        ;;
      4)
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
    printf "%sSettings → Health & Diagnostics%s

" "${C_BOLD}" "${C_RESET}"

    printf "Last run : %s
" "${CFG_HEALTH_LAST_RUN:-}"
    printf "OK       : %s
" "${CFG_HEALTH_OK:-false}"
    printf "Summary  : %s

" "${CFG_HEALTH_SUMMARY:-}"

    echo "1) Run health check now"
    echo "2) Show last health report"
    echo "3) Quick tool check"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) health_run_full; pause_enter ;;
      2) health_show_last; pause_enter ;;
      3) health_quick_tools; pause_enter ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}


# ------------------------- Optimizer (CPU/Nice + IO/Ionice) --------------------
opt_calc_nice() { echo $(( $1 - 20 )); }

opt_validate_range() {
  local val="$1" name="$2"
  [[ "$val" =~ ^-?[0-9]+$ ]] || { err "$name priority must be numeric."; return 1; }
  if (( val != 0 )); then
    if (( val < 5 || val > 20 )); then
      err "$name priority must be between 5 and 20 (or 0 to skip)."
      return 1
    fi
  fi
  return 0
}

optimizer_apply() {
  local target="${1:-$CFG_OPT_TARGET_KEYWORD}"
  local dpri="${2:-$CFG_OPT_DOCKER_PRI}"
  local npri="${3:-$CFG_OPT_NATIVE_PRI}"
  local verbose="${4:-$CFG_OPT_VERBOSE}"

  need_root || return 1

  opt_validate_range "$dpri" "Docker" || return 1
  opt_validate_range "$npri" "Native" || return 1

  local ionice_ok="0"
  has ionice && ionice_ok="1"

  local dnice nnice
  dnice="$(opt_calc_nice "$dpri")"
  nnice="$(opt_calc_nice "$npri")"

  header
  printf "%sOptimizer Run%s\n\n" "${C_BOLD}" "${C_RESET}"
  printf "Target keyword: %s\n" "$target"
  printf "Docker priority: %s (nice=%s)\n" "$dpri" "$dnice"
  printf "Native priority: %s (nice=%s)\n\n" "$npri" "$nnice"

  # Phase 1: Docker
  if (( dpri > 0 )); then
    if has docker; then
      local line cid cname cpid
      docker ps --format "{{.ID}} {{.Image}} {{.Names}}" | grep -i "$target" | while read -r line; do
        [[ -z "$line" ]] && continue
        cid="$(awk '{print $1}' <<<"$line")"
        cname="$(awk '{print $3}' <<<"$line")"
        cpid="$(docker inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null || echo 0)"
        [[ "$cpid" =~ ^[0-9]+$ ]] || cpid=0
        if (( cpid > 0 )); then
          renice -n "$dnice" -p "$cpid" &>/dev/null || true
          if (( ionice_ok == 1 )); then ionice -c 2 -n 0 -p "$cpid" &>/dev/null || true; fi
          printf "  %s[Docker]%s %s (PID %s) -> PRI %s: %sOK%s\n" "${C_PURPLE}" "${C_RESET}" "$cname" "$cpid" "$dpri" "${C_GREEN}" "${C_RESET}"
        fi
      done
    else
      warn "Docker command not found. Skipping Docker optimization."
    fi
  fi

  # Phase 2: Native (pgrep)
  if (( npri > 0 )); then
    local pids pid
    pids="$(pgrep -f "$target" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      for pid in $pids; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        (( pid == $$ )) && continue
        renice -n "$nnice" -p "$pid" &>/dev/null || true
        if (( ionice_ok == 1 )); then ionice -c 2 -n 0 -p "$pid" &>/dev/null || true; fi
        printf "  %s[Native]%s PID %s -> PRI %s: %sOK%s\n" "${C_BLUE}" "${C_RESET}" "$pid" "$npri" "${C_GREEN}" "${C_RESET}"
      done
    else
      info "No native processes found for keyword: $target"
    fi
  fi

  printf "\n"
  ok "Optimization complete."
  pause_enter
}

optimizer_status() {
  header
  printf "%sOptimizer Status%s\n\n" "${C_BOLD}" "${C_RESET}"
  printf "Target keyword: %s\n" "$CFG_OPT_TARGET_KEYWORD"
  printf "Configured priorities: Docker=%s Native=%s Verbose=%s\n\n" "$CFG_OPT_DOCKER_PRI" "$CFG_OPT_NATIVE_PRI" "$CFG_OPT_VERBOSE"

  printf "%sDocker matches%s\n" "${C_BOLD}" "${C_RESET}"
  if has docker; then
    docker ps --format "  {{.Names}}  (PID={{.ID}})" | grep -i "$CFG_OPT_TARGET_KEYWORD" >/dev/null 2>&1 || true
    docker ps --format "{{.ID}} {{.Names}}" | grep -i "$CFG_OPT_TARGET_KEYWORD" | while read -r cid cname; do
      local cpid ni
      cpid="$(docker inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null || echo 0)"
      ni="$(ps -o ni= -p "$cpid" 2>/dev/null | tr -d ' ' || echo '-')"
      printf "  %s%s%s PID=%s nice=%s\n" "${C_PURPLE}" "$cname" "${C_RESET}" "$cpid" "$ni"
    done
  else
    echo "  docker not found"
  fi

  printf "\n%sNative matches%s\n" "${C_BOLD}" "${C_RESET}"
  local pids pid
  pids="$(pgrep -f "$CFG_OPT_TARGET_KEYWORD" 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    echo "  none"
  else
    for pid in $pids; do
      (( pid == $$ )) && continue
      local cmd ni
      cmd="$(ps -o comm= -p "$pid" 2>/dev/null || echo '-')"
      ni="$(ps -o ni= -p "$pid" 2>/dev/null | tr -d ' ' || echo '-')"
      printf "  %sPID=%s%s cmd=%s nice=%s\n" "${C_BLUE}" "$pid" "${C_RESET}" "$cmd" "$ni"
    done
  fi

  pause_enter
}

optimizer_menu() {
  while true; do
    header
    printf "%sOptimizer Settings (Performance)%s\n\n" "${C_BOLD}" "${C_RESET}"
    printf "Target keyword: %s\n" "$CFG_OPT_TARGET_KEYWORD"
    printf "Docker priority: %s\n" "$CFG_OPT_DOCKER_PRI"
    printf "Native priority: %s\n" "$CFG_OPT_NATIVE_PRI"

    echo "1) Run Auto-Mode now (apply configured defaults)"
    echo "2) Set Docker priority (5-20, 0 skip)"
    echo "3) Set Native priority (5-20, 0 skip)"
    echo "4) Set target keyword"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1)
        optimizer_apply "$CFG_OPT_TARGET_KEYWORD" "$CFG_OPT_DOCKER_PRI" "$CFG_OPT_NATIVE_PRI" "false"
        ;;
      2)
        read -r -p "Docker priority (5-20, 0 skip): " v </dev/tty || true
        [[ -z "${v:-}" ]] && continue
        opt_validate_range "$v" "Docker" || { pause_enter; continue; }
        CFG_OPT_DOCKER_PRI="$v"
        config_save_optimizer_docker_pri "$v" || true
        config_load; init_colors
        ;;
      3)
        read -r -p "Native priority (5-20, 0 skip): " v </dev/tty || true
        [[ -z "${v:-}" ]] && continue
        opt_validate_range "$v" "Native" || { pause_enter; continue; }
        CFG_OPT_NATIVE_PRI="$v"
        config_save_optimizer_native_pri "$v" || true
        config_load; init_colors
        ;;
      4)
        read -r -p "Target keyword (default conduit): " v </dev/tty || true
        [[ -z "${v:-}" ]] && continue
        CFG_OPT_TARGET_KEYWORD="$v"
        config_save_optimizer_target "$v" || true
        config_load; init_colors
        ;;
      5)
        if [[ "$CFG_OPT_VERBOSE" == "true" ]]; then CFG_OPT_VERBOSE="false"; else CFG_OPT_VERBOSE="true"; fi
        config_save_optimizer_verbose "$CFG_OPT_VERBOSE" || true
        config_load; init_colors
        ;;
      6) optimizer_status ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

menu_settings() {
  while true; do
    header
    printf "%sSettings & Optimizer%s

" "${C_BOLD}" "${C_RESET}"
    echo "1) Network settings"
    echo "2) Console settings"
    echo "3) Optimizer Settings (Performance)"
    echo "4) Health status"
    echo "0) Back"
    echo
    read -r -p "Choice: " c </dev/tty || true
    case "${c:-}" in
      1) settings_network_menu ;;
      2) settings_console_menu ;;
      3) optimizer_menu ;;
      4) settings_health_menu ;;
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
    echo "5) Settings & Optimizer"
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
parse_args "$@"
config_load
init_colors
ui_selftest

# Run minimal preflight once on startup (non-blocking; detailed is delegated)
preflight_minimal

main_menu
