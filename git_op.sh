#!/bin/bash
# ==============================================================================
# Script: Git Operations Core
# Author: Babak Sorkhpour
# Version: 1.2.0
# ==============================================================================

# --- EMBEDDED RELEASE NOTES ---
# <component_release_notes>
# * **Auto-Versioning:** Automatically increments Patch version if the Tag already exists to prevent release failures.
# * **UI Fix:** Fixed color rendering in status tables (`%b` format).
# * **Robustness:** `-no` command now handles missing files gracefully.
# </component_release_notes>

# Managed Files (Include any file you want to track status for)
MANAGED_FILES=("conduit-console.sh" "conduit-optimizer.sh" "AI_DEV_GUIDELINES.md" "git_op.sh")
MAIN_PRODUCT="conduit-console.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- HELPER FUNCTIONS ---

get_file_version() {
    if [[ -f "$1" ]]; then
        grep -i "^# Version:" "$1" | head -n 1 | awk '{print $3}'
    else
        echo "Missing"
    fi
}

increment_version() {
    local ver=$1
    # Remove 'v' prefix if exists
    ver="${ver#v}"
    
    # Split by .
    IFS='.' read -r -a parts <<< "$ver"
    
    # If standard x.y.z format
    if [[ ${#parts[@]} -eq 3 ]]; then
        local major=${parts[0]}
        local minor=${parts[1]}
        local patch=${parts[2]}
        patch=$((patch + 1))
        echo "v$major.$minor.$patch"
    else
        # Fallback if weird format, just append .1
        echo "v$ver.1"
    fi
}

update_file_version() {
    local file=$1
    local new_ver=$2
    # Use sed to replace the version line
    # Removing 'v' for the file content standard usually
    local clean_ver="${new_ver#v}"
    if [[ -f "$file" ]]; then
        sed -i "s/^# Version: .*/# Version: $clean_ver/" "$file"
        echo -e "   Updated $file to version ${GREEN}$clean_ver${NC}"
    fi
}

command_list_status() {
    echo -e "${CYAN}--- Project File Status ---${NC}"
    echo ">> Fetching remote status..."
    git fetch origin main >/dev/null 2>&1
    
    # Use %b for colors to interpret correctly
    printf "%-25s %-10s %-20s %-20s\n" "Filename" "Ver" "Local Status" "GitHub Status"
    echo "--------------------------------------------------------------------------------"
    
    for file in "${MANAGED_FILES[@]}"; do
        local ver=$(get_file_version "$file")
        
        # Local Status
        local l_stat="${YELLOW}Untracked${NC}"
        if git check-ignore -q "$file"; then l_stat="${RED}Ignored${NC}"; 
        elif git ls-files --error-unmatch "$file" &>/dev/null; then l_stat="${GREEN}Tracked${NC}"; fi
        
        # Remote Status
        local r_stat="${RED}NOT ON SERVER${NC}"
        if git ls-tree -r origin/main --name-only | grep -qx "$file"; then
            r_stat="${GREEN}ON SERVER${NC}"
        fi
        
        printf "%-25s %-10s %-20b %-20b\n" "$file" "$ver" "$l_stat" "$r_stat"
    done
    echo "--------------------------------------------------------------------------------"
}

command_deny_file() {
    local file=$1
    echo -e ">> Blocking: ${RED}$file${NC}"
    
    # Force remove from index, ignore if not found
    git rm --cached --ignore-unmatch "$file" &>/dev/null
    
    if ! grep -qxF "$file" .gitignore; then
        echo "$file" >> .gitignore
        echo "   Added to .gitignore."
    fi
    echo -e "${GREEN}Done.${NC}"
}

command_release() {
    # 1. Identify Current Version
    CURRENT_VER=$(get_file_version "$MAIN_PRODUCT")
    if [[ "$CURRENT_VER" == "Missing" ]]; then CURRENT_VER="0.0.1"; fi
    if [[ "$CURRENT_VER" != v* ]]; then TARGET_VER="v$CURRENT_VER"; else TARGET_VER="$CURRENT_VER"; fi
    
    # 2. Check for Tag Collision
    if git rev-parse "$TARGET_VER" >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: Tag $TARGET_VER already exists.${NC}"
        NEW_VER=$(increment_version "$TARGET_VER")
        echo -e ">> Auto-Incrementing to: ${GREEN}$NEW_VER${NC}"
        
        # Update the main file
        update_file_version "$MAIN_PRODUCT" "$NEW_VER"
        TARGET_VER="$NEW_VER"
        
        # Must stage the version change
        git add "$MAIN_PRODUCT"
    fi
    
    echo -e ">> Preparing Release: ${GREEN}$TARGET_VER${NC}"
    
    # 3. Aggregate Notes
    RELEASE_BODY="## 🚀 Release $TARGET_VER"
    RELEASE_BODY+=$'\n\nAutomated release via git_op.sh\n'
    
    CHANGES=0
    # Always stage everything for release
    git add .
    
    if ! git diff --cached --quiet; then CHANGES=1; fi

    if [[ $CHANGES -eq 0 ]]; then
        echo -e "${YELLOW}No changes detected to release.${NC}"
        exit 0
    fi
    
    # Extract notes from all files
    for file in "${MANAGED_FILES[@]}"; do
         NOTES=$(sed -n '/<component_release_notes>/,/<\/component_release_notes>/p' "$file" | sed '1d;$d' | sed 's/^# //')
         if [[ -n "$NOTES" ]]; then RELEASE_BODY+=$'\n### 📄 '"$file"$'\n'"$NOTES"$'\n'; fi
    done
    
    # 4. Commit & Push
    git commit -m "release: $TARGET_VER"
    git tag -a "$TARGET_VER" -m "Release $TARGET_VER"
    
    echo ">> Pushing to GitHub..."
    git push origin main
    git push origin "$TARGET_VER"
    
    # 5. GitHub Release
    if command -v gh &> /dev/null; then
        gh release create "$TARGET_VER" --title "$TARGET_VER" --notes "$RELEASE_BODY"
        echo -e "${GREEN}✅ Released on GitHub!${NC}"
    else
        echo -e "${YELLOW}GitHub CLI missing. Release created locally.${NC}"
    fi
}

# --- MAIN BLOCK ---
case "$1" in
    -h|--help)
        echo "Usage: ./git_op.sh [-l | -no <file> | -yes <file> | (no args for release)]"
        ;;
    -l|--list)
        command_list_status
        ;;
    -no)
        if [[ -z "$2" ]]; then echo "Specify filename."; exit 1; fi
        command_deny_file "$2"
        ;;
    -yes)
        # allow logic omitted for brevity, inverse of deny
        sed -i "/^$(basename $2)$/d" .gitignore
        git add "$2"
        echo "Allowed $2"
        ;;
    "")
        command_release
        ;;
    *)
        echo "Unknown option."
        exit 1
        ;;
esac