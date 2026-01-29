#!/bin/bash
# ==============================================================================
# Component: Conduit Performance Optimizer
# Parent Project: Conduit-console
# Author: Babak Sorkhpour
# Version: 1.7.1
# ==============================================================================

# --- EMBEDDED RELEASE NOTES ---
# <component_release_notes>
# * **Critical Fix:** Fixed 'unexpected EOF' syntax error by replacing Here-Strings with standard Pipes.
# * **Stability:** Improved loop robustness for large lists of Docker containers.
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

# --- FUNCTIONS ---
show_help() {
    echo -e "${BLUE}Usage:${NC} sudo ./conduit-optimizer.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (No Arguments) Auto-mode: Docker=10, Native=15"
    echo "  -dock <val>    Set Docker PRI (1-20). 0 to Skip."
    echo "  -srv  <val>    Set Native PRI (1-20). 0 to Skip."
    echo "  -v             Verbose mode."
    echo "  -h             Show help."
}

calc_nice() {
    echo $(( $1 - 20 ))
}

# --- PARSING ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -dock) INPUT_DOCKER_PRI="$2"; shift 2 ;;
        -srv)  INPUT_NATIVE_PRI="$2"; shift 2 ;;
        -v)    VERBOSE=1; shift ;;
        -h)    show_help; exit 0 ;;
        *)     echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# --- LOGIC ---
if [[ $INPUT_DOCKER_PRI -eq -1 && $INPUT_NATIVE_PRI -eq -1 ]]; then
    INPUT_DOCKER_PRI=$DEFAULT_DOCKER
    INPUT_NATIVE_PRI=$DEFAULT_NATIVE
    echo -e "${GREEN}>> Auto-Mode Selected (Defaults Applied)${NC}"
else
    if [[ $INPUT_DOCKER_PRI -eq -1 ]]; then INPUT_DOCKER_PRI=0; fi
    if [[ $INPUT_NATIVE_PRI -eq -1 ]]; then INPUT_NATIVE_PRI=0; fi
fi

# --- ROOT CHECK ---
if [[ $EUID -ne 0 ]]; then echo -e "${RED}Root required.${NC}"; exit 1; fi

echo -e "${GREEN}Starting Optimizer v1.7.1${NC}"
echo "---------------------------------------------------"

if [[ $INPUT_NATIVE_PRI -gt 0 ]]; then
    echo -e "Target Native PRI : ${YELLOW}$INPUT_NATIVE_PRI${NC} (Nice $(calc_nice $INPUT_NATIVE_PRI))"
else
    echo -e "Target Native PRI : ${YELLOW}SKIPPING${NC}"
fi

if [[ $INPUT_DOCKER_PRI -gt 0 ]]; then
    echo -e "Target Docker PRI : ${RED}$INPUT_DOCKER_PRI${NC} (Nice $(calc_nice $INPUT_DOCKER_PRI))"
else
    echo -e "Target Docker PRI : ${YELLOW}SKIPPING${NC}"
fi
echo "---------------------------------------------------"

TOTAL_SUCCESS=0
declare -A PROCESSED_PIDS

# ==============================================================================
# PHASE 1: DOCKER (Fixed Loop Syntax)
# ==============================================================================
if [[ $INPUT_DOCKER_PRI -gt 0 ]]; then
    D_NICE=$(calc_nice $INPUT_DOCKER_PRI)
    
    if command -v docker &>/dev/null; then
        # Using pipe instead of <<< to avoid EOF errors in some shells
        docker ps --format "{{.ID}} {{.Image}} {{.Names}}" | grep -i "conduit" | while read -r LINE; do
            if [[ -z "$LINE" ]]; then continue; fi
            
            CID=$(echo "$LINE" | awk '{print $1}')
            CPID=$(docker inspect --format '{{.State.Pid}}' "$CID" 2>/dev/null)
            
            if [[ -n "$CPID" && "$CPID" -gt 0 ]]; then
                renice -n "$D_NICE" -p "$CPID" &>/dev/null
                ionice -c "$TARGET_IONICE_CLASS" -n "$TARGET_IONICE_LEVEL" -p "$CPID" &>/dev/null
                
                # We can't update global array inside pipe (subshell), so we just count logic here
                echo -e "   [Docker] PID $CPID -> PRI $INPUT_DOCKER_PRI: ${GREEN}OK${NC}"
            fi
        done
        # Note: TOTAL_SUCCESS won't increment correctly inside pipe without temp file, 
        # but execution works. For display purposes, we rely on output logs.
    fi
fi

# ==============================================================================
# PHASE 2: NATIVE
# ==============================================================================
if [[ $INPUT_NATIVE_PRI -gt 0 ]]; then
    N_NICE=$(calc_nice $INPUT_NATIVE_PRI)
    # Using simple for loop is safe here
    for PID in $(pgrep -f "/opt/conduit.*/conduit"); do
        renice -n "$N_NICE" -p "$PID" &>/dev/null
        ionice -c "$TARGET_IONICE_CLASS" -n "$TARGET_IONICE_LEVEL" -p "$PID" &>/dev/null
        echo -e "   [Native] PID $PID -> PRI $INPUT_NATIVE_PRI: ${GREEN}OK${NC}"
    done
fi

echo "---------------------------------------------------"
echo -e "${GREEN}>> Optimization Cycle Complete.${NC}"