#!/bin/bash
# ==============================================================================
# CORE TOOL: Git Operations & Release Manager
# Repository: https://github.com/babakskr/Conduit-console.git
# Description: Central hub for versioning, file management (allow/deny), and releasing.
# Author: Babak Sorkhpour
# ==============================================================================

# --- CONFIG ---
# Define the files managed by this core tool
MANAGED_FILES=("conduit-console.sh" "conduit-optimizer.sh" "AI_DEV_GUIDELINES.md" "git_op.sh")

# Main product file (Source of Truth for Repo Version)
MAIN_PRODUCT="conduit-console.sh" 

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- FUNCTIONS ---

get_file_version() {
    local file=$1
    if [[ -f "$file" ]]; then
        # Try to find "# Version: X.Y.Z"
        grep -i "^# Version:" "$file" | head -n 1 | awk '{print $3}'
    else
        echo "N/A"
    fi
}

get_git_status() {
    local file=$1
    # Check if ignored
    if git check-ignore -q "$file"; then
        echo "${RED}IGNORED (Local Only)${NC}"
        return
    fi
    # Check if tracked
    if git ls-files --error-unmatch "$file" &>/dev/null; then
        echo "${GREEN}PUBLISHED${NC}"
    else
        echo "${YELLOW}UNTRACKED${NC}"
    fi
}

command_list_status() {
    echo -e "${CYAN}--- Project File Status ---${NC}"
    printf "%-25s %-15s %-20s\n" "Filename" "Local Ver" "Git Status"
    echo "--------------------------------------------------------------"
    
    for file in "${MANAGED_FILES[@]}"; do
        local ver=$(get_file_version "$file")
        local stat=$(get_git_status "$file")
        printf "%-25s %-15s %b\n" "$file" "$ver" "$stat"
    done
    echo "--------------------------------------------------------------"
    
    # Show Last Release Info
    LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)
    echo -e "Latest Git Tag: ${YELLOW}${LAST_TAG:-None}${NC}"
}

command_deny_file() {
    local file=$1
    if [[ ! -f "$file" ]]; then echo "File not found: $file"; exit 1; fi
    
    echo -e ">> Blocking file from GitHub: ${RED}$file${NC}"
    
    # 1. Remove from Git index (keep local)
    git rm --cached "$file" &>/dev/null
    
    # 2. Add to .gitignore if not exists
    if ! grep -qxF "$file" .gitignore; then
        echo "$file" >> .gitignore
        echo "   Added to .gitignore"
    fi
    
    echo "   File removed from tracking."
}

command_allow_file() {
    local file=$1
    if [[ ! -f "$file" ]]; then echo "File not found: $file"; exit 1; fi

    echo -e ">> Allowing file to GitHub: ${GREEN}$file${NC}"
    
    # 1. Remove from .gitignore (Use sed to delete line matching filename exactly)
    sed -i "/^$(basename $file)$/d" .gitignore
    
    # 2. Add to Git
    git add "$file"
    echo "   Added to git staging."
}

command_release() {
    echo -e "${CYAN}>> Starting Release Process...${NC}"
    
    # 1. Determine Repo Version (From Main Product)
    # If conduit-console.sh doesn't exist, fallback to date or manual
    REPO_VER=$(get_file_version "$MAIN_PRODUCT")
    if [[ "$REPO_VER" == "N/A" ]]; then
        REPO_VER="v$(date +%Y.%m.%d)"
        echo -e "${YELLOW}Warning: Main product version not found. Using date: $REPO_VER${NC}"
    else
        # Ensure it has 'v' prefix
        if [[ "$REPO_VER" != v* ]]; then REPO_VER="v$REPO_VER"; fi
    fi
    
    echo -e "   Target Release Version: ${GREEN}$REPO_VER${NC}"

    # 2. Generate Release Notes
    # Scan all allowed files for <component_release_notes> block
    RELEASE_BODY="## 🚀 Release $REPO_VER"
    RELEASE_BODY+=$'\n\nThis release includes updates to the following components:\n'

    CHANGES_DETECTED=0

    for file in "${MANAGED_FILES[@]}"; do
        # Skip if ignored
        if git check-ignore -q "$file"; then continue; fi
        
        # Check if file is modified or staged
        if ! git diff --quiet "$file" || ! git diff --cached --quiet "$file"; then
             CHANGES_DETECTED=1
             # Extract notes
             NOTES=$(sed -n '/<component_release_notes>/,/<\/component_release_notes>/p' "$file" | sed '1d;$d' | sed 's/^# //')
             
             if [[ -n "$NOTES" ]]; then
                 RELEASE_BODY+=$'\n### 📄 '"$file"$'\n'"$NOTES"$'\n'
             fi
        fi
    done

    if [[ $CHANGES_DETECTED -eq 0 ]]; then
        echo -e "${YELLOW}No changes detected in managed files. Nothing to release.${NC}"
        # Force push option? For now, exit.
        exit 0
    fi

    echo -e "   Release Notes Generated."

    # 3. Git Operations
    git add .
    git commit -m "release: $REPO_VER"
    git tag -a "$REPO_VER" -m "Release $REPO_VER"
    
    echo -e ">> Pushing to Remote..."
    git push origin main
    git push origin "$REPO_VER"
    
    # 4. Create GitHub Release
    if command -v gh &> /dev/null; then
        echo -e ">> Publishing to GitHub Releases..."
        gh release create "$REPO_VER" --title "Release $REPO_VER" --notes "$RELEASE_BODY"
        echo -e "${GREEN}✅ Done!${NC}"
    else
        echo -e "${YELLOW}GitHub CLI (gh) not found. Tags pushed, please draft release manually.${NC}"
        echo -e "Notes:\n$RELEASE_BODY"
    fi
}

# --- MAIN EXECUTION ---

case "$1" in
    -l|--list)
        command_list_status
        ;;
    -no)
        if [[ -z "$2" ]]; then echo "Error: Specify filename."; exit 1; fi
        command_deny_file "$2"
        ;;
    -yes)
        if [[ -z "$2" ]]; then echo "Error: Specify filename."; exit 1; fi
        command_allow_file "$2"
        ;;
    *)
        # Default: Run Release
        command_release
        ;;
esac