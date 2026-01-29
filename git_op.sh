#!/bin/bash
# ==============================================================================
# Script: Git Operations Manager
# Author: Babak Sorkhpour
# Version: 1.1.0
# ==============================================================================

# --- EMBEDDED RELEASE NOTES ---
# <component_release_notes>
# * **New Feature:** Added `-h` flag for help menu.
# * **New Feature:** `-l` now checks Remote (GitHub) status using `ls-remote`.
# * **Security:** `-no` command now stages file deletion to remove it from GitHub on next push.
# * **Fix:** Prevented accidental release trigger when unknown arguments are passed.
# </component_release_notes>

# Managed Files
MANAGED_FILES=("conduit-console.sh" "conduit-optimizer.sh" "AI_DEV_GUIDELINES.md" "git_op.sh")
MAIN_PRODUCT="conduit-console.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- FUNCTIONS ---

show_help() {
    echo -e "${CYAN}Git Operations Manager v1.1.0${NC}"
    echo "Usage: ./git_op.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (No Args)   Perform full release (Add, Commit, Tag, Push)."
    echo "  -l          List file status (Local Version, Git Tracking, Remote Presence)."
    echo "  -no <file>  Block file (Add to .gitignore & Remove from GitHub)."
    echo "  -yes <file> Allow file (Remove from .gitignore & Add to Git)."
    echo "  -h          Show this help."
    echo ""
}

get_file_version() {
    if [[ -f "$1" ]]; then
        grep -i "^# Version:" "$1" | head -n 1 | awk '{print $3}'
    else
        echo "Missing"
    fi
}

check_remote_presence() {
    local file=$1
    # Check if file exists in the default branch of origin
    if git ls-tree -r origin/main --name-only | grep -qx "$file"; then
        echo "${GREEN}ON SERVER${NC}"
    else
        echo "${RED}NOT ON SERVER${NC}"
    fi
}

command_list_status() {
    echo -e "${CYAN}--- Project File Status ---${NC}"
    # Fetch latest remote info without merging
    echo ">> Fetching remote status..."
    git fetch origin main >/dev/null 2>&1
    
    printf "%-25s %-10s %-15s %-15s\n" "Filename" "Ver" "Local Status" "GitHub Status"
    echo "----------------------------------------------------------------------"
    
    for file in "${MANAGED_FILES[@]}"; do
        local ver=$(get_file_version "$file")
        
        # Local Status
        local l_stat="${YELLOW}Untracked${NC}"
        if git check-ignore -q "$file"; then l_stat="${RED}Ignored${NC}"; 
        elif git ls-files --error-unmatch "$file" &>/dev/null; then l_stat="${GREEN}Tracked${NC}"; fi
        
        # Remote Status
        local r_stat=$(check_remote_presence "$file")
        
        printf "%-25s %-10s %-15s %b\n" "$file" "$ver" "$l_stat" "$r_stat"
    done
    echo "----------------------------------------------------------------------"
}

command_deny_file() {
    local file=$1
    if [[ ! -f "$file" ]]; then echo "Error: File $file not found."; exit 1; fi
    
    echo -e ">> Blocking: ${RED}$file${NC}"
    
    # 1. Check if it exists on Remote
    git fetch origin main >/dev/null 2>&1
    if git ls-tree -r origin/main --name-only | grep -qx "$file"; then
        echo -e "   ${YELLOW}Warning:${NC} File exists on GitHub."
        echo "   Scheduling deletion... (Will be removed on next Release/Push)"
        git rm --cached "$file"
    else
        git rm --cached "$file" &>/dev/null
    fi
    
    # 2. Update .gitignore
    if ! grep -qxF "$file" .gitignore; then
        echo "$file" >> .gitignore
        echo "   Added to .gitignore."
    fi
    
    echo -e "${GREEN}Done.${NC} Run './git_op.sh' (Release) to apply changes to server."
}

command_allow_file() {
    local file=$1
    echo -e ">> Allowing: ${GREEN}$file${NC}"
    sed -i "/^$(basename $file)$/d" .gitignore
    git add "$file"
    echo "   Staged for next release."
}

command_release() {
    # 1. Identify Version
    REPO_VER=$(get_file_version "$MAIN_PRODUCT")
    if [[ "$REPO_VER" == "Missing" ]]; then REPO_VER="v$(date +%Y.%m.%d)"; fi
    if [[ "$REPO_VER" != v* ]]; then REPO_VER="v$REPO_VER"; fi
    
    echo -e ">> Preparing Release: ${GREEN}$REPO_VER${NC}"
    
    # 2. Aggregate Notes
    RELEASE_BODY="## 🚀 Release $REPO_VER"
    RELEASE_BODY+=$'\n\nAutomated release via git_op.sh\n'
    
    CHANGES=0
    for file in "${MANAGED_FILES[@]}"; do
        # Check if file has changes (staged or unstaged) or is new
        if ! git diff --quiet "$file" || ! git diff --cached --quiet "$file" || git ls-files --others --exclude-standard | grep -q "$file"; then
             CHANGES=1
             NOTES=$(sed -n '/<component_release_notes>/,/<\/component_release_notes>/p' "$file" | sed '1d;$d' | sed 's/^# //')
             if [[ -n "$NOTES" ]]; then RELEASE_BODY+=$'\n### 📄 '"$file"$'\n'"$NOTES"$'\n'; fi
        fi
    done
    
    # Also check if we have deletions (blocked files)
    if git diff --cached --name-only | grep -q "deleted file"; then CHANGES=1; fi

    if [[ $CHANGES -eq 0 ]]; then
        echo -e "${YELLOW}No changes detected to release.${NC}"
        exit 0
    fi
    
    # 3. Commit & Push
    git add .
    git commit -m "release: $REPO_VER"
    git tag -a "$REPO_VER" -m "Release $REPO_VER"
    
    echo ">> Pushing to GitHub..."
    git push origin main
    git push origin "$REPO_VER"
    
    # 4. GitHub Release
    if command -v gh &> /dev/null; then
        gh release create "$REPO_VER" --title "$REPO_VER" --notes "$RELEASE_BODY"
        echo -e "${GREEN}✅ Released on GitHub!${NC}"
    else
        echo -e "${YELLOW}GitHub CLI missing. Release created locally.${NC}"
        echo "Notes:"
        echo "$RELEASE_BODY"
    fi
}

# --- MAIN BLOCK ---
case "$1" in
    -h|--help)
        show_help
        ;;
    -l|--list)
        command_list_status
        ;;
    -no)
        if [[ -z "$2" ]]; then echo "Specify filename."; exit 1; fi
        command_deny_file "$2"
        ;;
    -yes)
        if [[ -z "$2" ]]; then echo "Specify filename."; exit 1; fi
        command_allow_file "$2"
        ;;
    "")
        command_release
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        show_help
        exit 1
        ;;
esac