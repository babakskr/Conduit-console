# Conduit Console Project

> **Auto-Generated Documentation** > This project provides a set of tools for managing Conduit instances (Native & Docker) and optimizing system performance.

## 🛠 Project Tools & Utility Overview

The following table serves as the **Single Source of Truth** for the tools included in this repository.
It is automatically updated during every release.

| File | Version | Description | Usage |
| :--- | :--- | :--- | :--- |
| `conduit-console.sh` | v0.2.7 | No description available. | `./conduit-console.sh [OPTIONS]` |
| `conduit-optimizer.sh` | v- | - | `-` |
| `AI_DEV_GUIDELINES.md` | v1.0.0-docs | No description available. | `-` |
| `git_op.sh` | v1.7.0 | Automates version control, README generation, and GitHub releases. | `${NC} ./git_op.sh [OPTION] [FILE...]` |
| `docs/` | DIR | Documentation and supplemental files. | Reference |

## 🚀 Installation & Setup

### Prerequisites
* **Linux OS** (Ubuntu/Debian recommended)
* **Root Privileges** (Required for service management and optimization)
* **Git** & **Docker** (Optional, for Docker mode)

### Quick Start
```bash
# 1. Clone the repository
git clone https://github.com/babakskr/Conduit-console.git
cd Conduit-console

# 2. Set permissions
chmod +x *.sh

# 3. Run the Main Console
sudo ./conduit-console.sh
```

## 🔄 Update & Release Management
This repository uses `git_op.sh` for automated releases.
* To check status: `./git_op.sh -l`
* To update/release: `./git_op.sh`

---
*Last Updated: Thu Jan 29 07:05:18 PM UTC 2026*
