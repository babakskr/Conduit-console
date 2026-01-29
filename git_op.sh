#!/bin/bash
# ==============================================================================
# Script: Git Operations Core
# Author: Babak Sorkhpour
# Version: 1.3.0
# ==============================================================================

# --- EMBEDDED RELEASE NOTES ---
# <component_release_notes>
# * **Critical Fix:** Implemented a `while` loop to find the next available Git Tag, preventing 'tag already exists' errors.
# * **Standard:** Added `-ver` flag.
# * **Stability:** `AI_DEV_GUIDELINES.md` is now tracked for versioning.
# </component_release_notes>

MANAGED_FILES=("conduit-console.sh" "conduit-optimizer.sh" "AI_DEV_GUIDELINES.md" "git_op.sh")
MAIN_PRODUCT="conduit-console.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- FUNCTIONS ---

show_version() {
    VER=$(grep "^# Version:" "$0" | awk '{print $3}')
    echo "Git Operations Manager - v$VER"
    echo "Author: Babak Sorkhpour"
}

get_file_version() {
    if [[ -f "$1" ]]; then
        # Try finding standard header, fallback for MD files if needed
        local v=$(grep -iE "^# Version:|^> \*\*Version:\*\*" "$1" | head -n 1 | awk '{print $NF}' | tr -d 'v')
        echo "${v:-Missing}"
    else
        echo "Missing"
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
        # Logic for .sh files (# Version:)
        sed -i "s/^# Version: .*/# Version: $new_ver/" "$file"
        # Logic for .md files (> **Version:**)
        sed -i "s/^> \*\*Version:\*\* .*/> **Version:** $new_ver/" "$file"
        echo -e "   Updated $file to version ${GREEN}$new_ver${NC}"
    fi
}

command_list_status() {
    echo -e "${CYAN}--- Project File Status ---${NC}"
    echo ">> Fetching remote status (git fetch)..."
    git fetch origin main >/dev/null 2>&1
    
    printf "%-25s %-10s %-20s %-20s\n" "Filename" "Ver" "Local Status" "GitHub Status"
    echo "--------------------------------------------------------------------------------"
    
    for file in "${MANAGED_FILES[@]}"; do
        local ver=$(get_file_version "$file")
        
        # Local Status
        local l_stat="${YELLOW}Untracked${NC}"
        if git check-ignore -q "$file"; then l_stat="${RED}Ignored${NC}"; 
        elif git ls-files --error-unmatch "$file" &>/dev/null; then l_stat="${GREEN}Tracked${NC}"; fi
        
        # Remote Status (Check against origin/main tree)
        local r_stat="${RED}NOT ON SERVER${NC}"
        if git ls-tree -r origin/main --name-only 2>/dev/null | grep -qx "$file"; then
            r_stat="${GREEN}ON SERVER${NC}"
        fi
        
        printf "%-25s %-10s %-20b %-20b\n" "$file" "$ver" "$l_stat" "$r_stat"
    done
    echo "--------------------------------------------------------------------------------"
}

command_release() {
    # 1. Identify Start Version
    RAW_VER=$(get_file_version "$MAIN_PRODUCT")
    if [[ "$RAW_VER" == "Missing" ]]; then RAW_VER="0.0.1"; fi
    
    # 2. Find Next Available Tag (The Fix)
    NEXT_VER="$RAW_VER"
    # Clean 'v' just in case
    NEXT_VER="${NEXT_VER#v}" 
    
    echo -e ">> Checking tag availability for v$NEXT_VER..."
    
    # Loop until we find a tag that DOES NOT exist
    while git rev-parse "v$NEXT_VER" >/dev/null 2>&1; do
        echo -e "   Tag v$NEXT_VER exists. Incrementing..."
        NEXT_VER=$(increment_version_string "$NEXT_VER")
    done
    
    TARGET_TAG="v$NEXT_VER"
    echo -e ">> Target Release: ${GREEN}$TARGET_TAG${NC}"

    # 3. Update File if Version Changed
    if [[ "$NEXT_VER" != "$RAW_VER" ]]; then
        update_file_version "$MAIN_PRODUCT" "$NEXT_VER"
        git add "$MAIN_PRODUCT"
    fi
    
    # 4. Generate Notes & Commit
    RELEASE_BODY="## 🚀 Release $TARGET_TAG"
    RELEASE_BODY+=$'\n\nAutomated release via git_op.sh\n'
    
    git add .
    CHANGES=0
    # Check if anything staged
    if ! git diff --cached --quiet; then CHANGES=1; fi
    
    if [[ $CHANGES -eq 0 ]]; then
        echo -e "${YELLOW}No changes detected to release.${NC}"
        exit 0
    fi
    
    for file in "${MANAGED_FILES[@]}"; do
         NOTES=$(sed -n '/<component_release_notes>/,/<\/component_release_notes>/p' "$file" | sed '1d;$d' | sed 's/^# //')
         if [[ -n "$NOTES" ]]; then RELEASE_BODY+=$'\n### 📄 '"$file"$'\n'"$NOTES"$'\n'; fi
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
}

# --- MAIN BLOCK ---
case "$1" in
    -h|--help)
        echo "Usage: ./git_op.sh [-l | -ver | -no <file> | -yes <file> | (no args for release)]"
        ;;
    -ver)
        show_version
        ;;
    -l|--list)
        command_list_status
        ;;
    -no)
        if [[ -z "$2" ]]; then echo "Specify filename."; exit 1; fi
        # ... (Same deny logic as before) ...
        git rm --cached --ignore-unmatch "$2" &>/dev/null
        if ! grep -qxF "$2" .gitignore; then echo "$2" >> .gitignore; fi
        echo "Blocked $2"
        ;;
    -yes)
        # ... (Same allow logic) ...
        sed -i "/^$(basename $2)$/d" .gitignore
        git add "$2"
        echo "Allowed $2"
        ;;
    "")
        command_release
        ;;
    *)
        echo "Unknown option. Use -h for help."
        exit 1
        ;;
esac