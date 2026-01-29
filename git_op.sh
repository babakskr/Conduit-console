#!/bin/bash
# ==============================================================================
# Script: Git Operations Manager (Core Release Tool)
# Repository: https://github.com/babakskr/Conduit-console.git
# Author: Babak Sorkhpour
# Version: 1.6.0
#
# Compliance:
# - Fixes: Supports multiple arguments for -no/-yes flags.
# - Feature: Dynamically scans ALL tracked files for release notes (not just managed list).
# - Implements KR-008 (Strict Help Standard)
# ==============================================================================

set -u -o pipefail
IFS=$'\n\t'

# Core files to show in status report (-l)
# (Release notes are now scanned dynamically from ALL files)
MANAGED_FILES=("conduit-console.sh" "conduit-optimizer.sh" "AI_DEV_GUIDELINES.md" "git_op.sh" "docs")
MAIN_PRODUCT="conduit-console.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- HELPER FUNCTIONS ---

show_version() {
    local ver
    ver=$(grep "^# Version:" "$0" | awk '{print $3}')
    echo "Git Operations Manager - v${ver:-Unknown}"
}

# KR-008: Strict Help Standard
show_help() {
    echo -e "${CYAN}Git Operations Manager (git_op)${NC}"
    echo "Description: Automates version control, file/folder tracking, and GitHub releases."
    echo ""
    echo -e "${YELLOW}Usage:${NC} ./git_op.sh [OPTION] [FILE...]"
    echo ""
    echo "Options:"
    echo "  (No Args)       Trigger a full release (Auto-Tag, Commit, Push)."
    echo "  -l              List status of core managed files."
    echo "  -no <files...>  Block files (Add to .gitignore & Remove from GitHub)."
    echo "  -yes <files...> Allow files (Remove from .gitignore & Add to Git)."
    echo "  -ver            Show script version."
    echo "  -h              Show this help message."
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  1. Release a new version (scans all files for notes):"
    echo "     ./git_op.sh"
    echo ""
    echo "  2. Block multiple files at once:"
    echo "     ./git_op.sh -no secrets.env temp.log .env"
    echo ""
    echo "  3. Allow/Track new scripts:"
    echo "     ./git_op.sh -yes custom_script.sh config.json"
    echo ""
}

get_file_version() {
    local target=$1
    if [[ -d "$target" ]]; then
        echo "DIR"
    elif [[ -f "$target" ]]; then
        # Support shell script (# Version:) and Markdown (> **Version:**)
        grep -iE "^# Version:|^> \*\*Version:\*\*" "$target" | head -n 1 | awk '{print $NF}' | tr -d 'v'
    else
        echo "-"
    fi
}

increment_version_string() {
    local ver=$1
    ver="${ver#v}"
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
    local clean_ver="${new_ver#v}"
    
    if [[ -f "$file" ]]; then
        sed -i "s/^# Version: .*/# Version: $clean_ver/" "$file"
        sed -i "s/^> \*\*Version:\*\* .*/> **Version:** $clean_ver/" "$file"
        echo -e "   Updated $file to version ${GREEN}$clean_ver${NC}"
    fi
}

# --- COMMANDS ---

command_list_status() {
    echo -e "${CYAN}--- Project Core Status ---${NC}"
    echo ">> Fetching remote status..."
    git fetch origin main >/dev/null 2>&1
    
    printf "%-25s %-10s %-25s %-15s\n" "Filename/Dir" "Ver" "Local Git Status" "Remote"
    echo "--------------------------------------------------------------------------------"
    
    for item in "${MANAGED_FILES[@]}"; do
        local ver
        ver=$(get_file_version "$item")
        
        # Local Status Logic
        local l_stat=""
        if git check-ignore -q "$item"; then
            l_stat="${RED}IGNORED (Blocked)${NC}"
        else
            local raw_stat
            raw_stat=$(git status --porcelain "$item" | awk '{print $1}' | head -n1)
            
            if [[ -z "$raw_stat" ]]; then
                 if [[ -e "$item" ]]; then
                    l_stat="${GREEN}Clean${NC}"
                 else
                    l_stat="${RED}MISSING (Local)${NC}"
                 fi
            else
                case "$raw_stat" in
                    "M")  l_stat="${YELLOW}Modified${NC}" ;;
                    "A")  l_stat="${GREEN}Staged${NC}" ;;
                    "??") l_stat="${BLUE}Untracked${NC}" ;;
                    *)    l_stat="${YELLOW}Changed ($raw_stat)${NC}" ;;
                esac
            fi
        fi
        
        # Remote Status Logic
        local r_stat="${RED}MISSING${NC}"
        if git ls-tree -r origin/main --name-only 2>/dev/null | grep -q "^$item"; then
            r_stat="${GREEN}SYNCED${NC}"
        elif git ls-tree -d origin/main --name-only 2>/dev/null | grep -qx "$item"; then
            r_stat="${GREEN}SYNCED (Dir)${NC}"
        fi
        
        printf "%-25s %-10s %-35b %-20b\n" "$item" "${ver:-?}" "$l_stat" "$r_stat"
    done
    echo "--------------------------------------------------------------------------------"
}

command_deny_file() {
    local file=$1
    echo -e ">> Blocking: ${RED}$file${NC}"
    git rm --cached -r --ignore-unmatch "$file" &>/dev/null
    
    if ! grep -qxF "$file" .gitignore; then
        echo "$file" >> .gitignore
        echo "   Added to .gitignore."
    fi
    echo -e "${GREEN}Done.${NC}"
}

command_allow_file() {
    local file=$1
    echo -e ">> Allowing: ${GREEN}$file${NC}"
    if [[ -f .gitignore ]]; then
        sed -i "/^$(basename "$file")$/d" .gitignore
    fi
    git add "$file"
    echo -e "${GREEN}Allowed and staged.${NC}"
}

command_release() {
    # 1. Identify Version
    local raw_ver
    raw_ver=$(get_file_version "$MAIN_PRODUCT")
    if [[ "$raw_ver" == "-" || "$raw_ver" == "Missing" ]]; then raw_ver="0.0.1"; fi
    
    # 2. Find Next Available Tag
    local next_ver="${raw_ver#v}"
    echo -e ">> Checking tag availability for v$next_ver..."
    while git rev-parse "v$next_ver" >/dev/null 2>&1; do
        echo -e "   Tag v$next_ver exists. Incrementing..."
        next_ver=$(increment_version_string "$next_ver")
    done
    local target_tag="v$next_ver"
    echo -e ">> Target Release: ${GREEN}$target_tag${NC}"

    # 3. Update File Content
    if [[ "$next_ver" != "${raw_ver#v}" ]]; then
        update_file_version "$MAIN_PRODUCT" "$next_ver"
        git add "$MAIN_PRODUCT"
    fi
    
    # 4. Generate Release Notes
    local release_body="## 🚀 Release $target_tag"
    release_body="${release_body}"$'\n\nAutomated release via git_op.sh\n'
    
    git add .
    if git diff --cached --quiet; then
        echo -e "${YELLOW}No changes detected to release.${NC}"
        if [[ "$next_ver" == "${raw_ver#v}" ]]; then exit 0; fi
    fi

    echo ">> Scanning ALL files for release notes..."
    # DYNAMIC SCAN: Find any file with release notes block
    # Using git grep to search all tracked files
    while IFS= read -r file; do
         local notes
         # Extract content between XML-like tags
         notes=$(sed -n '/<component_release_notes>/,/<\/component_release_notes>/p' "$file" | sed '1d;$d' | sed 's/^# //')
         if [[ -n "$notes" ]]; then 
            release_body="${release_body}"$'\n### 📄 '"$file"$'\n'"$notes"$'\n'
         fi
    done < <(git grep -l "<component_release_notes>")
    
    # 5. Commit & Push
    git commit -m "release: $target_tag"
    git tag -a "$target_tag" -m "Release $target_tag"
    
    echo ">> Pushing to GitHub..."
    git push origin main
    git push origin "$target_tag"
    
    # 6. GitHub Release
    if command -v gh &> /dev/null; then
        gh release create "$target_tag" --title "$target_tag" --notes "$release_body"
        echo -e "${GREEN}✅ Released on GitHub!${NC}"
    else
        echo -e "${YELLOW}GitHub CLI (gh) missing. Release created locally.${NC}"
    fi
}

# --- MAIN EXECUTION ---

# Check for no args
if [[ $# -eq 0 ]]; then
    command_release
    exit 0
fi

# Parse args loop
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -ver)
            show_version
            exit 0
            ;;
        -l|--list)
            command_list_status
            exit 0
            ;;
        -no)
            shift
            # Loop until next flag or end of args
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                command_deny_file "$1"
                shift
            done
            ;;
        -yes)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                command_allow_file "$1"
                shift
            done
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done