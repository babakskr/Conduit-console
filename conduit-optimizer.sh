#!/bin/bash
# ==============================================================================
# Component: Conduit Performance Optimizer
# Parent Project: Conduit-console
# Author: Babak Sorkhpour
# Version: 1.8.2
# ==============================================================================

# --- EMBEDDED RELEASE NOTES ---
# <component_release_notes>
# * **Documentation:** Updated `-h` to include detailed descriptions and usage examples.
# * **Standard:** Aligned with new CLI standards (Detailed Help).
# </component_release_notes>

# --- DEFAULTS ---
DEFAULT_DOCKER=10
DEFAULT_NATIVE=15
INPUT_DOCKER_PRI=-1
INPUT_NATIVE_PRI=-1
VERBOSE=0

# --- CONFIG ---
TARGET_IONICE_CLASS=2
TARGET_IONICE_LEVEL=0
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
CYAN='\033[0;36m'

# --- FUNCTIONS ---
show_version() {
    VER=$(grep "^# Version:" "$0" | awk '{print $3}')
    echo "Conduit Optimizer - v$VER"
    echo "Author: Babak Sorkhpour"
}

show_help() {
    echo -e "${CYAN}Conduit Performance Optimizer v$(grep "^# Version:" "$0" | awk '{print $3}')${NC}"
    echo "Description: Adjusts CPU (Nice) and I/O priorities for Conduit instances to prevent lag."
    echo ""
    echo -e "${YELLOW}Usage:${NC} sudo ./conduit-optimizer.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (No Args)      Auto-Mode: Sets Docker=10 (High) and Native=15 (Medium-High)."
    echo "  -dock <5-20>   Set Priority for Docker Containers."
    echo "                 (5=Max Performance, 10=High, 20=Normal). 0 to Skip."
    echo "  -srv  <5-20>   Set Priority for Native Services."
    echo "  -v             Verbose mode (Show detailed logs)."
    echo "  -ver           Show script version."
    echo "  -h             Show this help message."
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  1. Run with default settings (Recommended):"
    echo "     sudo ./conduit-optimizer.sh"
    echo ""
    echo "  2. Give Docker maximum power (PRI 5) and skip native services:"
    echo "     sudo ./conduit-optimizer.sh -dock 5 -srv 0"
    echo ""
    echo "  3. Set both to normal priority (Reset):"
    echo "     sudo ./conduit-optimizer.sh -dock 20 -srv 20"
    echo ""
}

calc_nice() { echo $(( $1 - 20 )); }

validate_range() {
    local val=$1; local name=$2
    if [[ $val -ne 0 ]]; then
        if [[ $val -lt 5 || $val -gt 20 ]]; then
            echo -e "${RED}[ERROR] $name Priority must be between 5 and 20.${NC}"; exit 1
        fi
    fi
}

# --- PARSING ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -dock) INPUT_DOCKER_PRI="$2"; shift 2 ;;
        -srv)  INPUT_NATIVE_PRI="$2"; shift 2 ;;
        -v)    VERBOSE=1; shift ;;
        -ver)  show_version; exit 0 ;;
        -h)    show_help; exit 0 ;;
        *)     echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- LOGIC ---
if [[ $INPUT_DOCKER_PRI -eq -1 && $INPUT_NATIVE_PRI -eq -1 ]]; then
    INPUT_DOCKER_PRI=$DEFAULT_DOCKER; INPUT_NATIVE_PRI=$DEFAULT_NATIVE
    echo -e "${GREEN}>> Auto-Mode Selected (Defaults Applied)${NC}"
else
    if [[ $INPUT_DOCKER_PRI -eq -1 ]]; then INPUT_DOCKER_PRI=0; fi
    if [[ $INPUT_NATIVE_PRI -eq -1 ]]; then INPUT_NATIVE_PRI=0; fi
fi

validate_range "$INPUT_DOCKER_PRI" "Docker"
validate_range "$INPUT_NATIVE_PRI" "Native"

if [[ $EUID -ne 0 ]]; then echo -e "${RED}Root required.${NC}"; exit 1; fi

echo -e "${GREEN}Starting Optimizer...${NC}"
echo "---------------------------------------------------"

# PHASE 1: DOCKER
TOTAL_SUCCESS=0
if [[ $INPUT_DOCKER_PRI -gt 0 ]]; then
    D_NICE=$(calc_nice $INPUT_DOCKER_PRI)
    if [[ $VERBOSE -eq 1 ]]; then echo -e "Target Docker PRI: $INPUT_DOCKER_PRI"; fi
    
    if command -v docker &>/dev/null; then
        # Using pipe loop for safety
        docker ps --format "{{.ID}} {{.Image}} {{.Names}}" | grep -i "conduit" | while read -r LINE; do
            if [[ -z "$LINE" ]]; then continue; fi
            CID=$(echo "$LINE" | awk '{print $1}')
            CPID=$(docker inspect --format '{{.State.Pid}}' "$CID" 2>/dev/null)
            if [[ -n "$CPID" && "$CPID" -gt 0 ]]; then
                renice -n "$D_NICE" -p "$CPID" &>/dev/null
                ionice -c "$TARGET_IONICE_CLASS" -n "$TARGET_IONICE_LEVEL" -p "$CPID" &>/dev/null
                echo -e "   [Docker] PID $CPID -> PRI $INPUT_DOCKER_PRI: ${GREEN}OK${NC}"
            fi
        done
    fi
fi

# PHASE 2: NATIVE
if [[ $INPUT_NATIVE_PRI -gt 0 ]]; then
    N_NICE=$(calc_nice $INPUT_NATIVE_PRI)
    if [[ $VERBOSE -eq 1 ]]; then echo -e "Target Native PRI: $INPUT_NATIVE_PRI"; fi
    
    for PID in $(pgrep -f "/opt/conduit.*/conduit"); do
        renice -n "$N_NICE" -p "$PID" &>/dev/null
        ionice -c "$TARGET_IONICE_CLASS" -n "$TARGET_IONICE_LEVEL" -p "$PID" &>/dev/null
        echo -e "   [Native] PID $PID -> PRI $INPUT_NATIVE_PRI: ${GREEN}OK${NC}"
    done
fi

echo "---------------------------------------------------"
echo -e "${GREEN}>> Done.${NC}"
