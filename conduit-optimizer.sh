#!/bin/bash
# ==============================================================================
# Project: Conduit-console | Module: Performance Optimizer
# Author: Babak Sorkhpour (Assisted by Gemini Pro)
# License: MIT
# Version: 1.4.0
# Description: Improved Docker detection (Image & Name) + Execution Fixes.
# ==============================================================================

# --- Configuration ---
PRIORITY_NATIVE_NICE=-5
PRIORITY_DOCKER_NICE=-10  # Higher priority for Docker
TARGET_IONICE_CLASS=2 
TARGET_IONICE_LEVEL=0

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- Root Check ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] Root privileges required.${NC}"
   exit 1
fi

echo -e "${GREEN}Starting Conduit Optimizer v1.4.0${NC}"
echo -e "Author: Babak Sorkhpour"
echo "---------------------------------------------------"

# Track PIDs to prevent double optimization (Native vs Docker overlap)
declare -A PROCESSED_PIDS

# ==============================================================================
# SECTION 1: DOCKER OPTIMIZATION (Priority 1)
# We run this FIRST to ensure Docker processes get the higher priority (-10)
# even if they are also detected by the native scanner later.
# ==============================================================================
echo -e "${BLUE}>> Phase 1: Scanning Docker Containers (Image & Name)...${NC}"

if command -v docker &>/dev/null; then
    # Search for containers where Image OR Name contains "conduit"
    # format: ID | Image | Names
    DOCKER_CANDIDATES=$(docker ps --format "{{.ID}} {{.Image}} {{.Names}}" | grep -i "conduit")

    if [[ -n "$DOCKER_CANDIDATES" ]]; then
        # Read line by line
        while read -r LINE; do
            CID=$(echo "$LINE" | awk '{print $1}')
            C_INFO=$(echo "$LINE" | awk '{$1=""; print $0}') # Rest of the string
            
            # Get Host PID
            CPID=$(docker inspect --format '{{.State.Pid}}' "$CID" 2>/dev/null)

            if [[ -n "$CPID" && "$CPID" -gt 0 ]]; then
                renice -n "$PRIORITY_DOCKER_NICE" -p "$CPID" &>/dev/null
                ionice -c "$TARGET_IONICE_CLASS" -n "$TARGET_IONICE_LEVEL" -p "$CPID" &>/dev/null
                
                PROCESSED_PIDS[$CPID]=1
                echo -e "   [Docker] Container $CID ($C_INFO)"
                echo -e "            PID: $CPID -> Nice $PRIORITY_DOCKER_NICE: ${GREEN}OK${NC}"
            fi
        done <<< "$DOCKER_CANDIDATES"
    else
        echo -e "   ${YELLOW}No active containers matching 'conduit' found.${NC}"
        echo -e "   (Debug: Ensure 'docker ps' shows running containers)"
    fi
else
    echo -e "   Docker not installed or not in PATH."
fi

# ==============================================================================
# SECTION 2: NATIVE OPTIMIZATION (Priority 2)
# ==============================================================================
echo -e "${BLUE}>> Phase 2: Scanning Native Processes...${NC}"

NATIVE_PIDS=$(pgrep -f "/opt/conduit.*/conduit")

if [[ -n "$NATIVE_PIDS" ]]; then
    for PID in $NATIVE_PIDS; do
        # Skip if already optimized as Docker
        if [[ ${PROCESSED_PIDS[$PID]} ]]; then
            continue
        fi

        renice -n "$PRIORITY_NATIVE_NICE" -p "$PID" &>/dev/null
        ionice -c "$TARGET_IONICE_CLASS" -n "$TARGET_IONICE_LEVEL" -p "$PID" &>/dev/null
        
        echo -e "   [Native] PID: $PID -> Nice $PRIORITY_NATIVE_NICE: ${GREEN}OK${NC}"
        PROCESSED_PIDS[$PID]=1
    done
else
    echo -e "   No native processes found."
fi

# ==============================================================================
# SECTION 3: VERIFICATION
# ==============================================================================
echo "---------------------------------------------------"
echo -e "${YELLOW}>> Phase 3: Final Verification${NC}"
COUNT=${#PROCESSED_PIDS[@]}
if [[ $COUNT -gt 0 ]]; then
    echo -e "${GREEN}>> SUCCESS: Optimized $COUNT processes.${NC}"
else
    echo -e "${RED}>> WARNING: No processes were optimized.${NC}"
fi