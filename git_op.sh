#!/bin/bash
# ==============================================================================
# Script: Git Operations Manager (Core Release Tool)
# Repository: https://github.com/babakskr/Conduit-console.git
# Author: Babak Sorkhpour
# Version: 1.8.0
#
# Compliance:
# - Feature: Generates a PROFESSIONAL GitHub README.md (Badges, TOC, Categorized Files).
# - Fixes: "Unbound variable" risks handled.
# - Implements KR-008 (Strict Help Standard).
# ==============================================================================

set -u -o pipefail
IFS=$'\n\t'

# Core tracking
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

show_help() {
    echo -e "${CYAN}Git Operations Manager (git_op)${NC}"
    echo "Description: Automates version control, Professional README generation, and GitHub releases."
    echo ""
    echo -e "${YELLOW}Usage:${NC} ./git_op.sh [OPTION] [FILE...]"
    echo ""
    echo "Options:"
    echo "  (No Args)       Trigger a full release (Update README, Tag, Commit, Push)."
    echo "  -l              List status of tracked files."
    echo "  -no <files...>  Block files (Add to .gitignore & Remove from GitHub)."
    echo "  -yes <files...> Allow files (Remove from .gitignore & Add to Git)."
    echo "  -ver            Show script version."
    echo "  -h              Show this help message."
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  1. Release a new version (Re-generates README.md entirely):"
    echo "     ./git_op.sh"
    echo ""
}

get_file_version() {
    local target=$1
    if [[ -d "$target" ]]; then
        echo "DIR"
    elif [[ -f "$target" ]]; then
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

# --- README GENERATOR ENGINE (Professional) ---

extract_desc() {
    local file=$1
    local desc="-"
    if [[ -f "$file" ]]; then
        # Try # Description: header
        desc=$(grep -i "^# Description:" "$file" | head -n1 | cut -d: -f2- | sed 's/^[ \t]*//')
        # Try inside code (echo "Description: ...")
        if [[ -z "$desc" ]]; then
            desc=$(grep -i "echo.*Description:" "$file" | head -n1 | cut -d: -f2- | sed 's/^[ \t]*//' | tr -d '"')
        fi
        # Fallbacks for specific docs
        if [[ -z "$desc" ]]; then
            case "$file" in
                "KNOWN_RISKS.md") desc="Official registry of known bugs and required guards." ;;
                "AI_HANDOFF.md")  desc="Operational log for AI collaboration and state tracking." ;;
                "ci-bash.yml")    desc="GitHub Actions workflow configuration." ;;
            esac
        fi
    fi
    echo "${desc:-No description provided.}"
}

generate_dynamic_readme() {
    echo -e ">> Generating professional ${CYAN}README.md${NC}..."
    local readme="README.md"
    
    # Get Global Version from Main Product
    local project_ver
    project_ver=$(get_file_version "$MAIN_PRODUCT")
    
    # --- 1. HEADER & BADGES ---
    cat > "$readme" <<EOF
# Conduit Console Manager

![Version](https://img.shields.io/badge/version-v${project_ver}-blue?style=flat-square)
![Platform](https://img.shields.io/badge/platform-Linux-green?style=flat-square)
![License](https://img.shields.io/badge/license-GPLv3-orange?style=flat-square)
![Bash](https://img.shields.io/badge/language-Bash-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)

> **Professional TUI for Conduit Management** > A unified console to manage Native (Systemd) and Docker instances of Conduit with real-time dashboards, performance optimization, and rigorous safety guards.

---

## 📋 Table of Contents
- [Features](#-features)
- [Project Structure](#-project-structure)
- [Installation](#-installation)
- [Usage](#-usage)
- [Documentation & Compliance](#-documentation--compliance)
- [Release Management](#-release-management)

---

## ✨ Features
* **Hybrid Management:** Control both Systemd services and Docker containers from one place.
* **Real-time Dashboard:** \`htop\`-style interface monitoring Traffic (RX/TX), Connections, and Uptime.
* **Performance Optimizer:** Dedicated tool to tune CPU/IO priority for high-load instances.
* **Safety First:** Strict \`set -u\` guards, input validation, and loop protection (see [KNOWN_RISKS.md](KNOWN_RISKS.md)).
* **Automated CI/CD:** Integrated release manager and Bash syntax validation.

---

## 📂 Project Structure

Below is the dynamic list of components tracked in this repository.

EOF

    # --- 2. DYNAMIC FILE TABLE (Categorized) ---
    
    echo "### 🔹 Core Components" >> "$readme"
    echo "| File | Ver | Description |" >> "$readme"
    echo "| :--- | :--- | :--- |" >> "$readme"
    
    # Scan for Shell Scripts (Core & Utils)
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
    echo "### 🔹 Documentation & Config" >> "$readme"
    echo "| File | Description |" >> "$readme"
    echo "| :--- | :--- |" >> "$readme"
    
    local -a doc_files
    mapfile -t doc_files < <(git ls-files | grep -E "\.(md|json|yml)$" | grep -v "README.md" | sort)
    for f in "${doc_files[@]}"; do
        echo "| \`$f\` | $(extract_desc "$f") |" >> "$readme"
    done
    
    # --- 3. INSTALLATION ---
    cat >> "$readme" <<EOF

---

## 🚀 Installation

### Prerequisites
1. **Linux OS** (Ubuntu 20.04+, Debian 11+)
2. **Root Privileges** (Required for systemd/docker control)
3. **Dependencies:** \`curl\`, \`jq\`, \`docker\` (optional), \`iproute2\`

### Quick Setup
\`\`\`bash
# 1. Clone Repository
git clone https://github.com/babakskr/Conduit-console.git
cd Conduit-console

# 2. Make Executable
chmod +x *.sh

# 3. Run Main Console
sudo ./conduit-console.sh
\`\`\`

---

## 🎮 Usage

### Main Console
The central hub for all operations.
\`\`\`bash
sudo ./conduit-console.sh
\`\`\`
*Navigate using numbers [1-4]. Press 'q' in Dashboard to return.*

### Performance Optimizer
Run this if you experience network lag or high load.
\`\`\`bash
# Auto-mode (Recommended)
sudo ./conduit-optimizer.sh

# Manual mode (e.g., Docker priority 5, Native priority 10)
sudo ./conduit-optimizer.sh -dock 5 -srv 10
\`\`\`

---

## 📚 Documentation & Compliance

This project adheres to strict development protocols.
* **[KNOWN_RISKS.md](KNOWN_RISKS.md):** Registry of past bugs and implemented guards (The "Constitution").
* **[AI_HANDOFF.md](AI_HANDOFF.md):** Coordination log for AI assistants.
* **[AI_DEV_GUIDELINES.md](AI_DEV_GUIDELINES.md):** Coding standards and prompt protocols.

---

## 🔄 Release Management

This repository creates releases automatically using \`git_op.sh\`.

| Command | Action |
| :--- | :--- |
| \`./git_op.sh -l\` | Check file status and version alignment. |
| \`./git_op.sh\` | **Full Release:** Update README, Tag Version, Push to GitHub. |

---
*Auto-generated by Git Operations Manager v$(get_file_version "git_op.sh") on $(date)*
EOF

    echo -e "   ${GREEN}Professional README.md generated.${NC}"
}

# --- COMMANDS ---

command_list_status() {
    echo -e "${CYAN}--- Project Core Status ---${NC}"
    echo ">> Fetching remote status..."
    git fetch origin main >/dev/null 2>&1
    
    printf "%-30s %-10s %-25s %-15s\n" "Filename" "Ver" "Local Git Status" "Remote"
    echo "-------------------------------------------------------------------------------------"
    
    # Dynamic list for status check
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
        if git ls-tree -r origin/main --name-only 2>/dev/null | grep -q "^$item"; then r_stat="${GREEN}SYNCED${NC}"; fi
        
        printf "%-30s %-10s %-35b %-20b\n" "$item" "${ver:-}" "$l_stat" "$r_stat"
    done
    echo "-------------------------------------------------------------------------------------"
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
    local raw_ver
    raw_ver=$(get_file_version "$MAIN_PRODUCT")
    if [[ "$raw_ver" == "-" || "$raw_ver" == "Missing" ]]; then raw_ver="0.0.1"; fi
    
    local next_ver="${raw_ver#v}"
    echo -e ">> Checking tag availability for v$next_ver..."
    while git rev-parse "v$next_ver" >/dev/null 2>&1; do
        echo -e "   Tag v$next_ver exists. Incrementing..."
        next_ver=$(increment_version_string "$next_ver")
    done
    local target_tag="v$next_ver"
    echo -e ">> Target Release: ${GREEN}$target_tag${NC}"

    if [[ "$next_ver" != "${raw_ver#v}" ]]; then
        update_file_version "$MAIN_PRODUCT" "$next_ver"
        git add "$MAIN_PRODUCT"
    fi
    
    # RE-GENERATE README BEFORE COMMIT
    generate_dynamic_readme
    git add README.md
    
    local release_body="## 🚀 Release $target_tag"
    release_body="${release_body}"$'\n\nAutomated release via git_op.sh\n'
    
    git add .
    if git diff --cached --quiet; then
        echo -e "${YELLOW}No changes detected to release.${NC}"
        if [[ "$next_ver" == "${raw_ver#v}" ]]; then exit 0; fi
    fi

    echo ">> Scanning ALL files for release notes..."
    while IFS= read -r file; do
         local notes
         notes=$(sed -n '/<component_release_notes>/,/<\/component_release_notes>/p' "$file" | sed '1d;$d' | sed 's/^# //')
         if [[ -n "$notes" ]]; then 
            release_body="${release_body}"$'\n### 📄 '"$file"$'\n'"$notes"$'\n'
         fi
    done < <(git grep -l "<component_release_notes>")
    
    git commit -m "release: $target_tag"
    git tag -a "$target_tag" -m "Release $target_tag"
    
    echo ">> Pushing to GitHub..."
    git push origin main
    git push origin "$target_tag"
    
    if command -v gh &> /dev/null; then
        gh release create "$target_tag" --title "$target_tag" --notes "$release_body"
        echo -e "${GREEN}✅ Released on GitHub!${NC}"
    else
        echo -e "${YELLOW}GitHub CLI missing. Local release only.${NC}"
    fi
}

# --- MAIN EXECUTION ---
if [[ $# -eq 0 ]]; then command_release; exit 0; fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help; exit 0 ;;
        -ver) show_version; exit 0 ;;
        -l|--list) command_list_status; exit 0 ;;
        -no) shift; while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do command_deny_file "$1"; shift; done ;;
        -yes) shift; while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do command_allow_file "$1"; shift; done ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; show_help; exit 1 ;;
    esac
done