#!/bin/bash
# ==============================================================================
# Script: Git Operations Core
# Author: Babak Sorkhpour
# Version: 1.4.1
# ==============================================================================

# --- EMBEDDED RELEASE NOTES ---
# <component_release_notes>
# * **Bug Fix:** Fixed syntax error (unexpected EOF) caused by complex quoting in release note generation.
# * **Reporting:** `-l` now provides a detailed status table (Local vs Remote).
# * **Standard:** Added Examples and Description to `-h`.
# </component_release_notes>

MANAGED_FILES=("conduit-console.sh" "conduit-optimizer.sh" "AI_DEV_GUIDELINES.md" "git_op.sh")
MAIN_PRODUCT="conduit-console.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- FUNCTIONS ---

show_version() {
    VER=$(grep "^# Version:" "$0" | awk '{print $3}')
    echo "Git Operations Manager - v$VER"
    echo "Author: Babak Sorkhpour"
}

show_help() {
    echo -e "${CYAN}Git Operations Manager (git_op) v$(grep "^# Version:" "$0" | awk '{print $3}')${NC}"
    echo "Description: Central hub for versioning, file management, and automated releasing."
    echo ""
    echo -e "${YELLOW}Usage:${NC} ./git_op.sh [OPTION]"
    echo ""
    echo "Options:"
    echo "  (No Args)   Perform a full release (Auto-Tag, Commit, Push)."
    echo "  -l          Show comprehensive status report (Local & Remote)."
    echo "  -ver        Show script version."
    echo "  -no <file>  Block a file (Add to .gitignore & Remove from GitHub)."
    echo "  -yes <file> Allow a file (Remove from .gitignore & Add to Git)."
    echo "  -h          Show this detailed help message."
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  1. Check status of all files:"
    echo "     ./git_op.sh -l"
    echo ""
    echo "  2. Create a new release (Auto-increment version):"
    echo "     ./git_op.sh"
    echo ""
    echo "  3. Stop tracking 'secrets.sh' and remove from GitHub:"
    echo "     ./git_op.sh -no secrets.sh"
    echo ""
}

get_file_version() {
    if [[ -f "$1" ]]; then
        local v=$(grep -iE "^# Version:|^> \*\*Version:\*\*" "$1" | head -n 1 | awk '{print $NF}' | tr -d 'v')
        echo "${v:-Missing}"
    else
        echo "-"
    fi
}

increment_version_string() {
    local ver=$1
    IFS='.' read -r -a parts <<< "$ver"
    if [[ ${#parts[@]} -eq 3 ]]; then
        local major=${parts[0]}
        local minor=${parts[1]}
        local patch=${parts[2]}
        patch=$((patch + 1))
        echo "$major.$minor.$patch"
    else
        echo "$ver.1"
    fi
}

update_file_version() {
    local file=$1
    local new_ver=$2
    if [[ -f "$file" ]]; then
        sed -i "s/^# Version: .*/# Version: $new_ver/" "$file"
        sed -i "s/^> \*\*Version:\*\* .*/> **Version:** $new_ver/" "$file"
        echo -e "   Updated $file to version ${GREEN}$new_ver${NC}"
    fi
}

command_list_status() {
    echo -e "${CYAN}--- Project Comprehensive Report ---${NC}"
    echo ">> Querying git status and remote origin..."
    git fetch origin main >/dev/null 2>&1
    
    # Table Header
    printf "%-25s %-10s %-35s %-15s\n" "Filename" "Ver" "Local Git Status" "Remote"
    echo "--------------------------------------------------------------------------------"
    
    for file in "${MANAGED_FILES[@]}"; do
        local ver=$(get_file_version "$file")
        
        # 1. Detailed Local Status
        local l_stat=""
        if git check-ignore -q "$file"; then
            l_stat="${RED}IGNORED (Blocked)${NC}"
        else
            # Check git status porcelain (M=Modified, A=Added, ??=Untracked)
            local raw_stat=$(git status --porcelain "$file" | awk '{print $1}')
            case "$raw_stat" in
                "M")  l_stat="${YELLOW}Modified (Needs Push)${NC}" ;;
                "A")  l_stat="${GREEN}Staged (Ready)${NC}" ;;
                "??") l_stat="${BLUE}Untracked (New)${NC}" ;;
                "")   l_stat="${GREEN}Clean (Up-to-date)${NC}" ;;
                *)    l_stat="$raw_stat" ;;
            esac
        fi
        
        # 2. Remote Status
        local r_stat="${RED}MISSING${NC}"
        if git ls-tree -r origin/main --name-only 2>/dev/null | grep -qx "$file"; then
            r_stat="${GREEN}SYNCED${NC}"
        fi
        
        printf "%-25s %-10s %-45b %-20b\n" "$file" "$ver" "$l_stat" "$r_stat"
    done
    echo "--------------------------------------------------------------------------------"
    echo -e "Legend: ${GREEN}Clean${NC}=No changes, ${YELLOW}Modified${NC}=Edited locally, ${BLUE}Untracked${NC}=New file"
}

command_release() {
    # 1. Identify Start Version
    RAW_VER=$(get_file_version "$MAIN_PRODUCT")
    if [[ "$RAW_VER" == "Missing" || "$RAW_VER" == "-" ]]; then RAW_VER="0.0.1"; fi
    
    # 2. Find Next Available Tag
    NEXT_VER="${RAW_VER#v}" 
    echo -e ">> Checking tag availability for v$NEXT_VER..."
    
    while git rev-parse "v$NEXT_VER" >/dev/null 2>&1; do
        echo -e "   Tag v$NEXT_VER exists. Incrementing..."
        NEXT_VER=$(increment_version_string "$NEXT_VER")
    done
    
    TARGET_TAG="v$NEXT_VER"
    echo -e ">> Target Release: ${GREEN}$TARGET_TAG${NC}"

    # 3. Update File if Version Changed
    if [[ "$NEXT_VER" != "${RAW_VER#v}" ]]; then
        update_file_version "$MAIN_PRODUCT" "$NEXT_VER"
        git add "$MAIN_PRODUCT"
    fi
    
    # 4. Generate Notes & Commit
    # Using simpler concatenation to avoid syntax errors
    RELEASE_BODY="## 🚀 Release $TARGET_TAG"
    RELEASE_BODY="${RELEASE_BODY}"$'\n\nAutomated release via git_op.sh\n'
    
    git add .
    if ! git diff --cached --quiet; then
        # Extract notes
        for file in "${MANAGED_FILES[@]}"; do
             # Capture notes safely
             NOTES=$(sed -n '/<component_release_notes>/,/<\/component_release_notes>/p' "$file" | sed '1d;$d' | sed 's/^# //')
             if [[ -n "$NOTES" ]]; then 
                RELEASE_BODY="${RELEASE_BODY}"$'\n### 📄 '"$file"$'\n'"$NOTES"$'\n'
             fi
        done
        
        git commit -m "release: $TARGET_TAG"
        git tag -a "$TARGET_TAG" -m "Release $TARGET_TAG"
        
        echo ">> Pushing to GitHub..."
        git push origin main
        git push origin "$TARGET_TAG"
        
        if command -v gh &> /dev/null; then
            gh release create "$TARGET_TAG" --title "$TARGET_TAG" --notes "$RELEASE_BODY"
            echo -e "${GREEN}✅ Released on GitHub!${NC}"
        else
            echo -e "${YELLOW}GitHub CLI missing. Release created locally.${NC}"
        fi
    else
        echo -e "${YELLOW}No changes detected to release.${NC}"
    fi
}

# --- MAIN BLOCK ---
case "$1" in
    -h|--help)   show_help ;;
    -ver)        show_version ;;
    -l|--list)   command_list_status ;;
    -no)
        if [[ -z "$2" ]]; then echo "Specify filename."; exit 1; fi
        git rm --cached --ignore-unmatch "$2" &>/dev/null
        if ! grep -qxF "$2" .gitignore; then echo "$2" >> .gitignore; fi
        echo "Blocked $2"
        ;;
    -yes)
        sed -i "/^$(basename $2)$/d" .gitignore
        git add "$2"
        echo "Allowed $2"
        ;;
    "") command_release ;;
    *)  echo "Unknown option. Use -h for help."; exit 1 ;;
esac