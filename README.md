# Conduit Console

![Version](https://img.shields.io/badge/version-v0.2.16-blue?style=flat-square)
![Branch](https://img.shields.io/badge/branch-main-purple?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-orange?style=flat-square)
![Author](https://img.shields.io/badge/author-Babak%20Sorkhpour-blueviolet?style=flat-square)

> **Professional Management Console** > A high-performance, bash-based tool to manage, monitor, and optimize Native (Systemd) and Docker instances.  
> *Developed & Maintained by [Babak Sorkhpour](https://github.com/babakskr)*

---

## 📋 Table of Contents
- [Project Overview](#-project-overview)
- [Installation](#-installation)
- [Tools Reference](#-tools-reference)
- [Configuration](#-configuration)
- [Development Guidelines](#-development-guidelines)

---

## 🚀 Installation

### Prerequisites
* **OS:** Linux (Ubuntu/Debian)
* **User:** Root privileges required.
* **Dependencies:** `curl`, `git`, `docker` (optional).

### Quick Start
```bash
# 1. Clone the repository
git clone https://github.com/babakskr/Conduit-console
cd Conduit-console

# 2. Set permissions
chmod +x *.sh

# 3. Run the Main Console
sudo ./conduit-console.sh
```

---

## 🛠 Tools Reference

### 1. Main Console (`conduit-console.sh`)
**Description:** The central hub for monitoring traffic, managing services, and viewing logs.
**Usage:**
```bash
sudo ./conduit-console.sh
```
**Key Features:**
* Real-time Traffic Dashboard (HTOP style).
* Auto-detection of Systemd services and Docker containers.
* Zero-dependency architecture.

### 2. Performance Optimizer (`conduit-optimizer.sh`)
**Description:** Adjusts CPU/IO priorities to prevent system lag under load.
**Usage:**
```bash
# Automatic Mode (Recommended)
sudo ./conduit-optimizer.sh

# Manual Mode (Custom Priorities)
sudo ./conduit-optimizer.sh -dock 5 -srv 10
```

### 3. Release Manager (`git_op.sh`)
**Description:** Automates versioning, documentation generation, and GitHub releases.
**Usage:**
```bash
./git_op.sh        # Create a full release
./git_op.sh -l     # Check project status
```

---

## ⚙️ Configuration

The project uses a central configuration file `project.conf`.
You can customize the project name, repository URL, and defaults by editing this file.

```bash
nano project.conf
```

---

## 📚 Development Guidelines

We follow strict strict coding standards to ensure stability and security.
Please refer to the following documents before contributing:

* **[AI_DEV_GUIDELINES.md](AI_DEV_GUIDELINES.md):** The "Constitution" for AI assistants and developers.
* **[KNOWN_RISKS.md](KNOWN_RISKS.md):** Registry of known bugs and required guards.
* **[AI_HANDOFF.md](AI_HANDOFF.md):** Operational log for development continuity.

---
*Last Updated: Thu Jan 29 08:40:26 PM UTC 2026* *© 2026 Babak Sorkhpour. All Rights Reserved.*
