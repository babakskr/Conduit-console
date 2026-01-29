#!/bin/bash
# ==============================================================================
# Script: Git Operations Manager (Core Release Tool)
# Repository: https://github.com/babakskr/Conduit-console.git
# Author: Babak Sorkhpour
# Version: 2.5.0
#
# Compliance:
# - Feature: No-args releases on CURRENT branch.
# - Feature: 'main' arg merges current branch to MAIN and releases.
# - Feature: Explicitly tracks and lists 'docs/' contents in README.
# - Safety: Sync-First policy enforced.
# ==============================================================================

set -u -o pipefail
IFS=$'\n\t'

# Load Configuration
CONFIG_FILE="project.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    MAIN_SCRIPT="conduit-console.sh"
    AUTHOR_NAME="Babak Sorkhpour"
    PROJECT_NAME="Conduit Console"
fi

MAIN_PRODUCT="${MAIN_SCRIPT}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- HELPER FUNCTIONS ---

check_error() {
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}>> ERROR: Operation failed. Aborting script.${NC}"
        echo -e "${YELLOW}>> Fix the issue manually and try again.${NC}"
        exit 1
    fi
}

show_version() {
    local ver
    ver=$(grep "^# Version:" "$0" | awk '{print $3}')
    echo "Git Operations Manager - v${ver:-Unknown}"
}

show_help() {
    echo -e "${CYAN}Git Operations Manager (git_op)${NC}"
    echo "Description: Automates version control, README generation, deletions, and GitHub releases."
    echo ""
    echo -e "${YELLOW}Usage:${NC} ./git_op.sh [COMMAND] [FILE...]"
    echo ""
    echo "Commands:"
    echo "  (No Args)       Release on the CURRENT branch (Dev/Stable mode)."
    echo "  main            Merge current branch to MAIN and release (Production mode)."
    echo ""
    echo "Options:"
    echo "  -l              List status of tracked files."
    echo "  -d <files...>   DELETE files permanently (Local + Remote)."
    echo "  -no <files...>  Block files (Add to .gitignore & Remove from GitHub)."
    echo "  -yes <files...> Allow files (Remove from .gitignore & Add to Git)."
    echo "  -ver            Show script version."
    echo "  -h              Show this help message."
}

get_file_version() {
    local target=$1
    if [[ -d "$target" ]]; then echo "DIR"; elif [[ -f "$target" ]]; then
        grep -iE "^# Version:|^> \*\*Version:\*\*" "$target" | head -n 1 | awk '{print $NF}' | tr -d 'v'
    else echo "-"; fi
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
    else echo "$ver.1"; fi
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

# --- ADVANCED README GENERATOR ---

extract_desc() {
    local file=$1
    local desc="-"
    if [[ -f "$file" ]]; then
        desc=$(grep -i "^# Description:" "$file" | head -n1 | cut -d: -f2- | sed 's/^[ \t]*//')
        if [[ -z "$desc" ]]; then
            desc=$(grep -i "echo.*Description:" "$file" | head -n1 | cut -d: -f2- | sed 's/^[ \t]*//' | tr -d '"')
        fi
        if [[ -z "$desc" ]]; then
            # Fallbacks
            case "$file" in
                "KNOWN_RISKS.md") desc="Registry of known bugs and guards." ;;
                "AI_HANDOFF.md")  desc="Operational log for AI collaboration." ;;
                "AI_DEV_GUIDELINES.md") desc="Development rules and prompts." ;;
                "AI_DEV_GUIDELINES_FA.md") desc="Development rules (Persian)." ;;
                "ci-bash.yml")    desc="GitHub Actions CI config." ;;
                "project.conf")   desc="Central configuration file." ;;
            esac
        fi
    fi
    echo "${desc:-No description provided.}"
}

generate_dynamic_readme() {
    local target_branch=$1
    echo -e ">> Generating professional ${CYAN}README.md${NC} on branch ${target_branch}..."
    local readme="README.md"
    local project_ver
    project_ver=$(get_file_version "$MAIN_PRODUCT")
    
    # Ensure new docs are visible to ls-files
    git add docs/ 2>/dev/null || true

    cat > "$readme" <<EOF
# ${PROJECT_NAME:-Conduit Console}

![Version](https://img.shields.io/badge/version-v${project_ver}-blue?style=flat-square)
![Branch](https://img.shields.io/badge/branch-${target_branch}-purple?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux-green?style=flat-square)
![License](https://img.shields.io/badge/license-${LICENSE_TYPE:-MIT}-orange?style=flat-square)
![Author](https://img.shields.io/badge/author-Babak%20Sorkhpour-blueviolet?style=flat-square)

> **Professional Management Console** > A high-performance, bash-based tool to manage, monitor, and optimize Native (Systemd) and Docker instances.  
> *Developed by ${AUTHOR_NAME}*

---

## 📋 Table of Contents
- [Project Overview](#-project-overview)
- [Installation](#-installation)
- [Tools Reference](#-tools-reference)
- [Documentation](#-documentation)
- [Release Management](#-release-management)

---

## 📂 Project Structure (Manifest)

EOF
    
    echo "### 🔹 Core Components" >> "$readme"
    echo "| File | Ver | Description |" >> "$readme"
    echo "| :--- | :--- | :--- |" >> "$readme"
    
    local -a sh_files
    mapfile -t sh_files < <(git ls-files | grep "\.sh$" | grep -v "git_op.sh" | sort)
    for f in "${sh_files[@]}"; do
        echo "| \`$f\` | v$(get_file_version "$f") | $(extract_desc "$f") |" >> "$readme"
    done

    echo "" >> "$readme"
    echo "### 🔹 Utilities & Automation" >> "$readme"
    echo "| File | Ver | Description |" >> "$readme"
    echo "| :--- | :--- | :--- |" >> "$readme"
    echo "| \`git_op.sh\` | v$(get_file_version "git_op.sh") | $(extract_desc "git_op.sh") |" >> "$readme"
    
    echo "" >> "$readme"
    echo "### 🔹 Documentation (Root)" >> "$readme"
    echo "| File | Description |" >> "$readme"
    echo "| :--- | :--- |" >> "$readme"
    
    local -a doc_files
    mapfile -t doc_files < <(git ls-files | grep -E "\.(md|json|yml|conf)$" | grep -v "README.md" | grep -v "^docs/" | sort)
    for f in "${doc_files[@]}"; do
        echo "| \`$f\` | $(extract_desc "$f") |" >> "$readme"
    done

    # Specifically list docs folder contents
    if [[ -d "docs" ]]; then
        echo "" >> "$readme"
        echo "### 🔹 Documentation (Folder: \`docs/\`)" >> "$readme"
        echo "| File | Description |" >> "$readme"
        echo "| :--- | :--- |" >> "$readme"
        local -a sub_docs
        mapfile -t sub_docs < <(git ls-files "docs/*.md" | sort)
        for f in "${sub_docs[@]}"; do
            echo "| \`$f\` | $(extract_desc "$f") |" >> "$readme"
        done
    fi
    
    cat >> "$readme" <<EOF

---

## 🚀 Installation

### Quick Setup
\`\`\`bash
git clone ${REPO_URL:-...}
cd ${PROJECT_SLUG:-Conduit-console}
chmod +x *.sh
sudo ./${MAIN_SCRIPT}
\`\`\`

---

## 🔄 Release Management

| Command | Action |
| :--- | :--- |
| \`./git_op.sh\` | **Current Release:** Release on the CURRENT branch. |
| \`./git_op.sh main\` | **Prod Release:** Merge to MAIN and Release. |
| \`./git_op.sh -d <file>\` | **Delete:** Remove file locally and remotely. |

---
*Generated by Git Operations Manager v$(get_file_version "git_op.sh") on $(date)*
EOF

    echo -e "   ${GREEN}README.md updated.${NC}"
}

# --- COMMANDS ---

command_list_status() {
    echo -e "${CYAN}--- Project Core Status ---${NC}"
    echo ">> Fetching remote status..."
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    git fetch origin "$branch" >/dev/null 2>&1
    
    printf "%-30s %-10s %-25s %-15s\n" "Filename" "Ver" "Local Git Status" "Remote"
    echo "-------------------------------------------------------------------------------------"
    local -a files
    mapfile -t files < <(git ls-files | sort)
    for item in "${files[@]}"; do
        local ver
        ver=$(get_file_version "$item")
        local l_stat=""
        local raw_stat
        raw_stat=$(git status --porcelain "$item" | awk '{print $1}' | head -n1)
        if [[ -z "$raw_stat" ]]; then l_stat="${GREEN}Clean${NC}"; else l_stat="${YELLOW}Modified${NC}"; fi
        local r_stat="${RED}MISSING${NC}"
        if git ls-tree -r origin/"$branch" --name-only 2>/dev/null | grep -q "^$item"; then r_stat="${GREEN}SYNCED${NC}"; fi
        printf "%-30s %-10s %-35b %-20b\n" "$item" "${ver:-}" "$l_stat" "$r_stat"
    done
    echo "-------------------------------------------------------------------------------------"
}

command_delete_files() {
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD)
    
    for file in "$@"; do
        if [[ "$file" == "git_op.sh" || "$file" == "project.conf" ]]; then
            echo -e "${RED}>> SKIP: Cannot delete core tool '$file'.${NC}"; continue;
        fi
        echo -e ">> Deleting: ${RED}$file${NC}..."
        git rm -f "$file" 2>/dev/null || rm -f "$file"
        if [[ -f .gitignore ]]; then sed -i "/^$(basename "$file")$/d" .gitignore; fi
    done
    
    echo ">> Committing deletions..."
    git commit -m "delete: removed files via git_op"
    check_error
    echo ">> Pushing changes to $branch..."
    git push origin "$branch"
    check_error
    echo -e "${GREEN}>> Files deleted locally and remotely.${NC}"
}

command_deny_file() {
    local file=$1
    echo -e ">> Blocking: ${RED}$file${NC}"
    git rm --cached -r --ignore-unmatch "$file" &>/dev/null
    if ! grep -qxF "$file" .gitignore; then echo "$file" >> .gitignore; fi
    echo -e "${GREEN}Done.${NC}"
}

command_allow_file() {
    local file=$1
    echo -e ">> Allowing: ${GREEN}$file${NC}"
    if [[ -f .gitignore ]]; then sed -i "/^$(basename "$file")$/d" .gitignore; fi
    git add "$file"
    echo -e "${GREEN}Allowed and staged.${NC}"
}

command_release() {
    local mode=$1  # "current" or "main"
    
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    echo -e ">> Working on branch: ${CYAN}$current_branch${NC}"
    
    echo ">> Syncing with remote (git pull)..."
    git pull origin "$current_branch"
    check_error
    
    # 1. DETERMINE TARGET BRANCH
    local target_branch="$current_branch"
    
    if [[ "$mode" == "main" && "$current_branch" != "main" ]]; then
        target_branch="main"
        echo -e ">> Mode: MAIN (Merge ${current_branch} -> main)"
        
        # Switch to main
        git checkout main || git checkout -b main "origin/main"
        git pull origin main
        
        # Merge
        echo -e ">> Merging ${CYAN}$current_branch${NC} into main..."
        git merge "$current_branch" -m "merge: release from $current_branch"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}>> MERGE CONFLICT! Fix manually.${NC}"; exit 1;
        fi
    else
        echo -e ">> Mode: CURRENT (Releasing on ${current_branch})"
    fi

    # 2. Versioning
    local raw_ver
    raw_ver=$(get_file_version "$MAIN_PRODUCT")
    if [[ "$raw_ver" == "-" || "$raw_ver" == "Missing" ]]; then raw_ver="0.0.1"; fi
    
    local next_ver="${raw_ver#v}"
    echo -e ">> Checking tag availability for v$next_ver..."
    while git rev-parse "v$next_ver" >/dev/null 2>&1; do
        next_ver=$(increment_version_string "$next_ver")
    done
    local target_tag="v$next_ver"
    echo -e ">> Target Release: ${GREEN}$target_tag${NC}"

    if [[ "$next_ver" != "${raw_ver#v}" ]]; then
        update_file_version "$MAIN_PRODUCT" "$next_ver"
        git add "$MAIN_PRODUCT"
    fi
    
    # 3. GENERATE README (Pass target branch name for badge)
    # Ensure all docs are staged so they appear in README
    git add . 
    generate_dynamic_readme "$target_branch"
    git add README.md
    
    # 4. Commit & Tag
    local release_body="## 🚀 Release $target_tag"
    release_body="${release_body}"$'\n\nAutomated release via git_op.sh\n'
    
    while IFS= read -r file; do
         local notes
         notes=$(sed -n '/<component_release_notes>/,/<\/component_release_notes>/p' "$file" | sed '1d;$d' | sed 's/^# //')
         if [[ -n "$notes" ]]; then 
            release_body="${release_body}"$'\n### 📄 '"$file"$'\n'"$notes"$'\n'
         fi
    done < <(git grep -l "<component_release_notes>")
    
    git commit -m "release: $target_tag (Docs Updated)"
    check_error
    
    echo ">> Pushing to $target_branch..."
    git push origin "$target_branch"
    check_error
    
    echo ">> Pushing tag..."
    git tag -a "$target_tag" -m "Release $target_tag"
    git push origin "$target_tag"
    check_error
    
    if command -v gh &> /dev/null; then
        gh release create "$target_tag" --title "$target_tag" --notes "$release_body"
        echo -e "${GREEN}✅ Released on GitHub!${NC}"
    else
        echo -e "${YELLOW}GitHub CLI missing. Local release only.${NC}"
    fi
    
    # If we switched to main, stay there? Or go back? Usually staying on main is safer after release.
    # If users want to go back, they can checkout dev again.
}

# --- MAIN EXECUTION ---

if [[ $# -eq 0 ]]; then
    # No args -> Release on CURRENT branch
    command_release "current"
    exit 0
fi

if [[ "$1" == "main" ]]; then
    # Main arg -> Merge to MAIN and release
    command_release "main"
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -ver) show_version; exit 0 ;;
        -l|--list) command_list_status; exit 0 ;;
        -d) 
            shift
            files_to_delete=()
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do files_to_delete+=("$1"); shift; done
            command_delete_files "${files_to_delete[@]}"
            ;;
        -no) 
            shift; while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do command_deny_file "$1"; shift; done 
            ;;
        -yes) 
            shift; while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do command_allow_file "$1"; shift; done 
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; show_help; exit 1 ;;
    esac
done