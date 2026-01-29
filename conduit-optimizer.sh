#!/bin/bash
# ==============================================================================
# Project: Conduit-console | Module: Performance Optimizer
# Repo: https://github.com/babakskr/Conduit-console.git
# Author: Babak Sorkhpour (Assisted by Gemini Pro)
# License: MIT
# Version: 1.5.0
# ==============================================================================

# --- RELEASE NOTES (Auto-parsed by git_op.sh) ---
# <release_notes>
# ## ?? Release v1.5.0: CLI & Custom Priorities
#
# **Key Changes:**
# * **New CLI Args:** Added `-dock` and `-srv` to set custom target priorities manually.
# * **Logic Update:** Inputs now map to Linux PRI column (Target 10 = Nice -10).
# * **Verbose Mode:** Added `-v` for detailed output logging.
# * **Help Menu:** Added `-h` for quick usage guide.
# * **Safety Range:** Inputs restricted to 5-20 (0 to skip).
# </release_notes>

# --- DEFAULTS ---
# Default Target PRI (Linux Priority Column):
# 10 = High Priority (Nice -10) -> For Docker
# 15 = Medium-High Priority (Nice -5) -> For Native Services
DEFAULT_DOCKER_PRI=10
DEFAULT_NATIVE_PRI=15

# Inputs (Initialized with Defaults)
INPUT_DOCKER_PRI=$DEFAULT_DOCKER_PRI
INPUT_NATIVE_PRI=$DEFAULT_NATIVE_PRI
VERBOSE=0

# --- CONFIG ---
TARGET_IONICE_CLASS=2
TARGET_IONICE_LEVEL=0

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- FUNCTIONS ---

show_help() {
    echo -e "${BLUE}Conduit Performance Optimizer v1.5.0${NC}"
    echo -e "Repo: https://github.com/babakskr/Conduit-console.git"
    echo ""
    echo "Usage: sudo $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h          Show this help message"
    echo "  -v          Verbose mode (show detailed logs)"
    echo "  -dock <val> Set Target Priority for Docker (Range: 5-20, Default: 10, 0: Skip)"
    echo "  -srv  <val> Set Target Priority for Native Services (Range: 5-20, Default: 15, 0: Skip)"
    echo ""
    echo "Concept:"
    echo "  Value matches Linux 'PRI' column."
    echo "  10 = Very High (Nice -10)"
    echo "  15 = High (Nice -5)"
    echo "  20 = Normal (Nice 0)"
    echo ""
}

log_verbose() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "$1"
    fi
}

validate_input() {
    local val=$1
    local name=$2
    if [[ "$val" -eq 0 ]]; then
        return 0 # 0 means skip
    fi
    if [[ "$val" -lt 5 || "$val" -gt 20 ]]; then
        echo -e "${RED}[ERROR] $name priority must be between 5 and 20 (or 0 to skip).${NC}"
        exit 1
    fi
}

calc_nice() {
    # Formula: Nice = Target_PRI - 20
    # Example: Input 10 -> 10 - 20 = -10 (Nice)
    echo $(( $1 - 20 ))
}

# --- CLI PARSING ---
while getopts "hvd:s:" opt; do
  case ${opt} in
    h ) show_help; exit 0 ;;
    v ) VERBOSE=1 ;;
    d ) INPUT_DOCKER_PRI=$OPTARG ;;
    s ) INPUT_NATIVE_PRI=$OPTARG ;;
    \? ) show_help; exit 1 ;;
  esac
done

# --- ROOT CHECK ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] Root privileges required.${NC}"
   exit 1
fi

# --- VALIDATION ---
validate_input "$INPUT_DOCKER_PRI" "Docker"
validate_input "$INPUT_NATIVE_PRI" "Native Service"

echo -e "${GREEN}Starting Conduit Optimizer v1.5.0${NC}"
echo -e "Author: Babak Sorkhpour"
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

# Track PIDs
declare -A PROCESSED_PIDS
TOTAL_SUCCESS=0

# ==============================================================================
# PHASE 1: DOCKER
# ==============================================================================
if [[ $INPUT_DOCKER_PRI -gt 0 ]]; then
    log_verbose "${BLUE}>> Phase 1: Scanning Docker Containers...${NC}"
    
    TARGET_NICE=$(calc_nice $INPUT_DOCKER_PRI)

    if command -v docker &>/dev/null; then
        DOCKER_CANDIDATES=$(docker ps --format "{{.ID}} {{.Image}} {{.Names}}" | grep -i "conduit")
        
        if [[ -n "$DOCKER_CANDIDATES" ]]; then
            while read -r LINE; do
                CID=$(echo "$LINE" | awk '{print $1}')
                C_INFO=$(echo "$LINE" | awk '{$1=""; print $0}')
                CPID=$(docker inspect --format '{{.State.Pid}}' "$CID" 2>/dev/null)

                if [[ -n "$CPID" && "$CPID" -gt 0 ]]; then
                    renice -n "$TARGET_NICE" -p "$CPID" &>/dev/null
                    ionice -c "$TARGET_IONICE_CLASS" -n "$TARGET_IONICE_LEVEL" -p "$CPID" &>/dev/null
                    
                    PROCESSED_PIDS[$CPID]=1
                    echo -e "   [Docker] Container $CID -> PRI $INPUT_DOCKER_PRI: ${GREEN}OK${NC}"
                    log_verbose "            (Info: $C_INFO)"
                    ((TOTAL_SUCCESS++))
                fi
            done <<< "$DOCKER_CANDIDATES"
        else
            log_verbose "   No active Docker containers found."
        fi
    fi
fi

# ==============================================================================
# PHASE 2: NATIVE
# ==============================================================================
if [[ $INPUT_NATIVE_PRI -gt 0 ]]; then
    log_verbose "${BLUE}>> Phase 2: Scanning Native Processes...${NC}"
    
    TARGET_NICE=$(calc_nice $INPUT_NATIVE_PRI)
    NATIVE_PIDS=$(pgrep -f "/opt/conduit.*/conduit")

    if [[ -n "$NATIVE_PIDS" ]]; then
        for PID in $NATIVE_PIDS; do
            if [[ ${PROCESSED_PIDS[$PID]} ]]; then continue; fi

            renice -n "$TARGET_NICE" -p "$PID" &>/dev/null
            ionice -c "$TARGET_IONICE_CLASS" -n "$TARGET_IONICE_LEVEL" -p "$PID" &>/dev/null
            
            echo -e "   [Native] PID: $PID -> PRI $INPUT_NATIVE_PRI: ${GREEN}OK${NC}"
            PROCESSED_PIDS[$PID]=1
            ((TOTAL_SUCCESS++))
        done
    else
        log_verbose "   No native processes found."
    fi
fi

# ==============================================================================
# PHASE 3: VERIFICATION
# ==============================================================================
echo "---------------------------------------------------"
if [[ $TOTAL_SUCCESS -gt 0 ]]; then
    echo -e "${GREEN}>> SUCCESS: Optimized $TOTAL_SUCCESS processes.${NC}"
else
    echo -e "${YELLOW}>> DONE: No eligible processes found or operations skipped.${NC}"
fi