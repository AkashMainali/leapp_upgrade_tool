production_readme = """<div align="center">

# Red Hat Enterprise Linux Leapp Upgrade Manager
### Enterprise-grade, automated lifecycle migration tool for RHEL 7 &rarr; 8 and RHEL 8 &rarr; 9

[![RHEL](https://img.shields.io/badge/Platform-RHEL%207%20%7C%208%20%7C%209-CC0000.svg?logo=redhat&logoColor=white)](https://www.redhat.com/en/technologies/linux-platforms/enterprise-linux)
[![Bash](https://img.shields.io/badge/Language-Bash%204+-4EAA25.svg?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Python](https://img.shields.io/badge/Runtime-Python%202.7%20%7C%203.x-3776AB.svg?logo=python&logoColor=white)](https://www.python.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-brightgreen.svg)]()

<p align="center">
  <b>Safe, idempotent, and production-ready automation wrapper around Red Hat Leapp.</b><br>
  Features interactive CLI validation, automated dependency management, dynamic inhibitor remediation generation, rich executive HTML dashboard reporting, and post-upgrade configuration auditing.
</p>

[Quick Start](#-quick-start) •
[Architecture](#-architecture--workflow) •
[Key Features](#-core-features) •
[Reporting Dashboards](#-interactive-reporting-dashboards) •
[Troubleshooting](#-troubleshooting)

</div>

---

## 📌 Overview

Upgrading Enterprise Linux across major release boundaries is high-risk. Unresolved kernel blockers, deprecated authentication plugins, missed answerfile confirmations, and repository mapping discrepancies routinely break migrations mid-stream.

**Leapp Upgrade Manager** wraps the standard `leapp` utility in an end-to-end operational framework:
- **Prevents illegal version leaps** (e.g., stops users from attempting an unsupported RHEL 7 &rarr; RHEL 9 jump).
- **Auto-generates remediation scripts** by extracting unanswered dialog questions and inhibitor commands directly from assessment data.
- **Delivers interactive HTML5 dashboards** with metrics cards, real-time search, and copy-paste remediation commands.
- **Protects third-party software** by maintaining non-Red Hat RPMs, libraries, and custom repo definitions throughout and after migration.
- **Resolves environment friction** via automatic runtime discovery (`python3`, `python2`, `/usr/libexec/platform-python`) and user permission restoration (`chown` back to invoking user).

---

## 🚀 Quick Start

### 1. Clone & Permissions
```bash
git clone [https://github.com/AkashMainali/leapp_upgrade_tool.git](https://github.com/AkashMainali/leapp_upgrade_tool.git)
cd leapp_upgrade_tool
chmod +x leapp_upgrade_manager.sh