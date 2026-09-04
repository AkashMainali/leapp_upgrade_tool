#!/usr/bin/env bash
#
# leapp_upgrade_manager.sh
# Enterprise Leapp upgrade automation for RHEL 7 -> 8 and RHEL 8 -> 9
# Features interactive CLI confirmation, automated pre-req installation,
# safety guardrails, pre-upgrade artifact collection, inhibitor remediations,
# dynamic remediation_answer.sh generation with direct HTML/UI execution,
# dynamic Python detection (python3/python2/python),
# non-root artifact ownership fixing (chown to invoking sudo user),
# and dedicated post-upgrade assessment reporting (preserving third-party repos/packages).
#

set -euo pipefail

# ------------------------------------------------------------------------------
# Privilege & Environment Check
# ------------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] This script must be executed as root." >&2
    exit 1
fi

if [[ ! -f /etc/redhat-release ]]; then
    echo "[ERROR] /etc/redhat-release not found. Cannot determine OS version." >&2
    exit 1
fi

RELEASE_TEXT=$(cat /etc/redhat-release)

# Directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine invoking non-root user (for artifact permissions)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "root")}"
REAL_GROUP="$(id -gn "${REAL_USER}" 2>/dev/null || echo "root")"

# Detect appropriate Python interpreter (RHEL 8 defaults to python3; RHEL 7 has python2/python)
detect_python() {
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
    elif command -v python >/dev/null 2>&1; then
        echo "python"
    elif command -v python2 >/dev/null 2>&1; then
        echo "python2"
    elif command -v /usr/libexec/platform-python >/dev/null 2>&1; then
        echo "/usr/libexec/platform-python"
    else
        echo "[ERROR] No Python binary detected (checked python3, python, python2, /usr/libexec/platform-python)." >&2
        echo "        Please install python3: dnf install -y python3" >&2
        exit 1
    fi
}
PYTHON_BIN="$(detect_python)"

# Helper function to fix ownership of created directories & files to the non-root user
chown_to_real_user() {
    local target_path="$1"
    if [[ "$REAL_USER" != "root" && -e "$target_path" ]]; then
        chown -R "${REAL_USER}:${REAL_GROUP}" "$target_path" 2>/dev/null || true
    fi
}

# Use FQDN if configured; fallback to standard hostname
HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Determine current and target RHEL version; reject direct RHEL 7 -> 9 migrations
if grep -qE "release 7\." /etc/redhat-release; then
    CURRENT_MAJOR=7
    TARGET_MAJOR=8
elif grep -qE "release 8\." /etc/redhat-release; then
    CURRENT_MAJOR=8
    TARGET_MAJOR=9
elif grep -qE "release 9\." /etc/redhat-release; then
    CURRENT_MAJOR=9
    TARGET_MAJOR="N/A"
else
    echo "[ERROR] Unsupported or unrecognized RHEL version: ${RELEASE_TEXT}" >&2
    exit 1
fi

# Artifact directories & HTML files
PRE_DIR="${SCRIPT_DIR}/leapp_artifacts_${HOSTNAME_VAL}_${TIMESTAMP}"
PRE_HTML="${PRE_DIR}/${HOSTNAME_VAL}_Leapp_pre_upgrade_report_${TIMESTAMP}.html"
REMEDIATION_SH="${PRE_DIR}/remediation_answer.sh"

POST_DIR="${SCRIPT_DIR}/leapp_post_artifacts_${HOSTNAME_VAL}_${TIMESTAMP}"
POST_HTML="${POST_DIR}/${HOSTNAME_VAL}_Leapp_post_upgrade_report_${TIMESTAMP}.html"

# ------------------------------------------------------------------------------
# User Confirmation Prompt
# ------------------------------------------------------------------------------
confirm_run() {
    local action="$1"
    echo ""
    echo "================================================================================"
    echo "                    LEAPP UPGRADE ASSISTANT - PRE-FLIGHT                        "
    echo "================================================================================"
    echo " Hostname          : ${HOSTNAME_VAL}"
    echo " Detected OS       : ${RELEASE_TEXT}"
    echo " Current Version   : Red Hat Enterprise Linux ${CURRENT_MAJOR}"
    echo " Target Version    : Red Hat Enterprise Linux ${TARGET_MAJOR}"
    echo " Action Selected   : ${action}"
    echo " Python Binary     : ${PYTHON_BIN}"
    echo " Artifact Owner    : ${REAL_USER}:${REAL_GROUP}"
    echo " Policy Note       : Third-party repos, packages, and custom files preserved."
    echo "================================================================================"
    
    read -rp "Proceed with '${action}' on this system? [y/N]: " initial_confirm
    if [[ ! "$initial_confirm" =~ ^[yY](es)?$ ]]; then
        echo "[INFO] Operation aborted by user."
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# Action: install-pre-req
# ------------------------------------------------------------------------------
install_pre_req() {
    if [[ "$CURRENT_MAJOR" -eq 9 ]]; then
        echo "[ERROR] System is on RHEL 9. No further Leapp path configured." >&2
        exit 1
    fi
    confirm_run "install-pre-req"

    echo "[INFO] Enabling official repositories and installing Leapp packages..."
    if [[ "$CURRENT_MAJOR" -eq 7 ]]; then
        subscription-manager repos --enable rhel-7-server-rpms || true
        subscription-manager repos --enable rhel-7-server-extras-rpms || true
        yum clean all
        yum install -y leapp leapp-upgrade-el7toel8 cockpit-leapp
    elif [[ "$CURRENT_MAJOR" -eq 8 ]]; then
        subscription-manager repos --enable rhel-8-for-x86_64-baseos-rpms || true
        subscription-manager repos --enable rhel-8-for-x86_64-appstream-rpms || true
        dnf clean all
        dnf install -y leapp leapp-upgrade-el8toel9 cockpit-leapp python3
    fi

    echo "[SUCCESS] Pre-requisites and Leapp migration modules installed successfully."
}

# ------------------------------------------------------------------------------
# Generate Pre-Upgrade HTML Report & remediation_answer.sh
# ------------------------------------------------------------------------------
generate_pre_html_report() {
    local json_report="/var/log/leapp/leapp-report.json"
    local txt_report="/var/log/leapp/leapp-report.txt"
    local ans_file="/var/log/leapp/answerfile"

    "$PYTHON_BIN" - "$json_report" "$txt_report" "$ans_file" "$PRE_HTML" "$REMEDIATION_SH" "$HOSTNAME_VAL" "$CURRENT_MAJOR" "$TARGET_MAJOR" << 'EOF'
import json
import os
import sys
import datetime
import re

try:
    import html
    def escape_html(text): return html.escape(str(text))
except ImportError:
    import cgi
    def escape_html(text): return cgi.escape(str(text), quote=True)

json_path, txt_path, ans_path, out_html, out_remediation_sh, hostname, curr_major, target_major = sys.argv[1:9]

KNOWN_SOLUTIONS = [
    {
        "keywords": ["newest installed kernel not in use", "booted kernel"],
        "title": "Booted Kernel Mismatch",
        "steps": "The running kernel does not match the latest installed kernel version.",
        "commands": "reboot\n# After reboot, verify running kernel matches newest:\nuname -r\nrpm -q --last kernel | head -n1"
    },
    {
        "keywords": ["missing required answers in the answer file", "answerfile", "confirm_removal"],
        "title": "Unanswered Confirmation Prompts",
        "steps": "Leapp requires explicit administrative consent for module/package removal.",
        "commands": "leapp answer --section remove_pam_pkcs11_module_check.confirm=True"
    },
    {
        "keywords": ["permitrootlogin", "openssh", "root login"],
        "title": "OpenSSH PermitRootLogin Deprecation",
        "steps": "RHEL 8/9 disables PermitRootLogin yes by default. Set it explicitly in sshd configuration.",
        "commands": "sed -i -E 's/^[#]*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config\nsystemctl restart sshd"
    },
    {
        "keywords": ["packages available in excluded repositories", "excluded repositories"],
        "title": "Excluded Target Repositories",
        "steps": "Packages are present from repositories not enabled in target version. Check repository mappings or enable required channels.",
        "commands": "# Review excluded repositories in Leapp logs:\ngrep -i 'excluded' /var/log/leapp/leapp-report.txt\n# Update subscription-manager status:\nsubscription-manager refresh"
    },
    {
        "keywords": ["difference in python versions", "python 2", "python version"],
        "title": "Python 2 / Python 3 Runtime Migration",
        "steps": "RHEL 8 replaces system Python with unversioned python3. Review custom scripts referencing /usr/bin/python.",
        "commands": "alternatives --set python /usr/bin/python3 2>/dev/null || true"
    },
    {
        "keywords": ["grub2 core will be automatically updated", "grub2"],
        "title": "GRUB2 Bootloader Update Verification",
        "steps": "Verify your EFI or BIOS bootloader disk location to ensure boot records are updated cleanly.",
        "commands": "# Inspect current boot disk:\nlsblk -p"
    },
    {
        "keywords": ["kernel module", "unsupported kernel", "pata_acpi"],
        "title": "Deprecated/Removed Kernel Modules",
        "steps": "Modules removed in the target kernel must be unloaded prior to migration.",
        "commands": "modprobe -r pata_acpi 2>/dev/null || true\necho 'blacklist pata_acpi' >> /etc/modprobe.d/leapp_upgrade_blacklist.conf"
    }
]

pending_dialog_sections = []
if os.path.exists(ans_path):
    try:
        with open(ans_path, 'r') as f:
            content = f.read()
            sections = re.findall(r'\[([a-zA-Z0-9_\.]+)\]', content)
            for s in sections:
                pending_dialog_sections.append(s.strip())
    except Exception as e:
        print("[WARN] Error inspecting answerfile: %s" % e)

entries = []
remediation_commands_list = []

if os.path.exists(json_path):
    try:
        with open(json_path, 'r') as f:
            data = json.load(f)
            raw_entries = data.get("entries", [])
            for item in raw_entries:
                sev = item.get("severity", "info").lower()
                flags = item.get("flags", [])
                is_inhibitor = "inhibitor" in flags
                
                if is_inhibitor:
                    sev_level = "inhibitor"
                elif sev in ["high", "error"]:
                    sev_level = "high"
                elif sev in ["medium", "warning"]:
                    sev_level = "medium"
                elif sev == "low":
                    sev_level = "low"
                else:
                    sev_level = "info"

                title = item.get("title", "Untitled Finding")
                summary = item.get("summary", "")
                
                remediation_cmds = []
                detail = item.get("detail", {})
                if isinstance(detail, dict) and "remediations" in detail:
                    for rem in detail["remediations"]:
                        if isinstance(rem, dict):
                            ctx = rem.get("context")
                            if rem.get("type") == "command" and isinstance(ctx, list):
                                cmd_str = " ".join(ctx)
                                remediation_cmds.append(cmd_str)
                                remediation_commands_list.append((title, cmd_str))
                            elif isinstance(ctx, str):
                                if "alternatives" in ctx or "leapp answer" in ctx:
                                    match = re.search(r'"([^"]+)"', ctx)
                                    if match:
                                        remediation_cmds.append(match.group(1))
                                    else:
                                        remediation_cmds.append(ctx)
                                else:
                                    remediation_cmds.append("# Hint: " + ctx)

                sol_cmds = "\n".join(remediation_cmds) if remediation_cmds else ""
                
                if not sol_cmds:
                    comb = (title + " " + summary).lower()
                    for k in KNOWN_SOLUTIONS:
                        for kw in k["keywords"]:
                            if kw in comb:
                                sol_cmds = k["commands"]
                                break
                        if sol_cmds: break

                if is_inhibitor and "answer" in (title + " " + summary).lower():
                    if pending_dialog_sections:
                        for s in pending_dialog_sections:
                            ans_cmd = "sudo leapp answer --section %s.confirm=True" % s
                            if ans_cmd not in sol_cmds:
                                sol_cmds = ans_cmd + ("\n" + sol_cmds if sol_cmds else "")
                                remediation_commands_list.append((title, ans_cmd))
                    elif "remove_pam_pkcs11" in (title + " " + summary).lower() or "remove_pam_pkcs11" in str(detail):
                        ans_cmd = "sudo leapp answer --section remove_pam_pkcs11_module_check.confirm=True"
                        if ans_cmd not in sol_cmds:
                            sol_cmds = ans_cmd + ("\n" + sol_cmds if sol_cmds else "")
                            remediation_commands_list.append((title, ans_cmd))

                entries.append({
                    "severity": sev_level,
                    "title": title,
                    "summary": summary,
                    "commands": sol_cmds
                })
    except Exception as e:
        print("[WARN] Could not parse leapp-report.json (%s)." % e)

order = {"inhibitor": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
entries.sort(key=lambda x: order.get(x["severity"], 5))

counts = {"inhibitor": 0, "high": 0, "medium": 0, "low": 0, "info": 0}
for e in entries:
    counts[e["severity"]] = counts.get(e["severity"], 0) + 1

remediation_sh_lines = [
    "#!/usr/bin/env bash",
    "# Auto-generated Leapp Remediation Answer Script",
    "# Generated for: " + hostname + " at " + datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "#",
    "set -euo pipefail",
    "",
    "echo '========================================================================'",
    "echo ' Applying Leapp Answers and Inhibitor Resolutions for " + hostname + "'",
    "echo '========================================================================'",
    ""
]

if pending_dialog_sections:
    for s in pending_dialog_sections:
        remediation_sh_lines.append("# Dialog Answer: " + s)
        remediation_sh_lines.append("echo '[INFO] Answering section: " + s + "...'")
        remediation_sh_lines.append("sudo leapp answer --section " + s + ".confirm=True")
        remediation_sh_lines.append("")
else:
    for e in entries:
        if "remove_pam_pkcs11" in (e["title"] + " " + e["summary"]):
            remediation_sh_lines.append("# Dialog Answer: remove_pam_pkcs11_module_check")
            remediation_sh_lines.append("echo '[INFO] Answering section: remove_pam_pkcs11_module_check...'")
            remediation_sh_lines.append("sudo leapp answer --section remove_pam_pkcs11_module_check.confirm=True")
            remediation_sh_lines.append("")
            break

for title, cmd in remediation_commands_list:
    if "leapp answer" not in cmd:
        remediation_sh_lines.append("# Finding: " + title)
        remediation_sh_lines.append("echo '[INFO] Running remediation for: " + title[:45] + "...'")
        remediation_sh_lines.append(cmd)
        remediation_sh_lines.append("")

remediation_sh_lines.append("echo '========================================================================'")
remediation_sh_lines.append("echo ' [SUCCESS] All remediation answers applied.'")
remediation_sh_lines.append("echo ' You can now re-run: sudo ./leapp_upgrade_manager.sh upgrade'")
remediation_sh_lines.append("echo '========================================================================'")
remediation_sh_lines.append("")

with open(out_remediation_sh, 'w') as f:
    f.write("\n".join(remediation_sh_lines))
os.chmod(out_remediation_sh, 0o755)

with open(out_remediation_sh, 'r') as f:
    sh_content_raw = f.read()

now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

html_doc = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Red Hat Leapp Pre-upgrade Assessment & Remediation - """ + escape_html(hostname) + """</title>
  <style>
    :root {
      --bg: #0f172a; --card-bg: #ffffff; --page-bg: #f8fafc; --text-main: #0f172a;
      --text-muted: #475569; --border: #e2e8f0; --color-inhibitor: #e11d48;
      --color-high: #ea580c; --color-medium: #d97706; --color-low: #2563eb; --color-info: #059669;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background-color: var(--page-bg); color: var(--text-main); padding: 32px 20px; }
    .container { max-width: 1240px; margin: 0 auto; }
    .header { background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%); color: #ffffff; padding: 28px 32px; border-radius: 12px; display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); }
    .header h1 { font-size: 22px; font-weight: 700; margin-bottom: 4px; }
    .header .subtitle { color: #94a3b8; font-size: 14px; }
    .header .badge { background: rgba(255,255,255,0.1); border: 1px solid rgba(255,255,255,0.2); padding: 8px 18px; border-radius: 9999px; font-size: 14px; font-weight: 600; }
    
    .generator-card {
      background: #ffffff;
      border: 1px solid #cbd5e1;
      border-top: 5px solid #0284c7;
      border-radius: 8px;
      padding: 22px 24px;
      margin-bottom: 24px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.05);
    }
    .generator-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
    .generator-title { font-size: 16px; font-weight: 700; color: #0f172a; }
    .generator-badge { background: #e0f2fe; color: #0369a1; padding: 4px 12px; border-radius: 9999px; font-size: 12px; font-weight: 600; }
    
    .inhibitor-alert { background: #fff1f2; border: 1px solid #fecdd3; border-left: 6px solid #e11d48; border-radius: 8px; padding: 16px 20px; margin-bottom: 24px; display: flex; align-items: center; justify-content: space-between; }
    .inhibitor-alert-text { color: #9f1239; font-size: 14.5px; font-weight: 600; }
    
    .metrics-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 16px; margin-bottom: 24px; }
    .metric-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px; padding: 16px 20px; cursor: pointer; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
    .metric-label { font-size: 11px; font-weight: 700; text-transform: uppercase; color: var(--text-muted); }
    .metric-value { font-size: 28px; font-weight: 700; margin-top: 4px; }
    .val-inhibitor { color: var(--color-inhibitor); } .val-high { color: var(--color-high); } .val-medium { color: var(--color-medium); } .val-low { color: var(--color-low); } .val-info { color: var(--color-info); }
    
    .toolbar { display: flex; gap: 12px; margin-bottom: 20px; }
    .search-input { flex: 1; padding: 12px 18px; font-size: 14px; border: 1px solid var(--border); border-radius: 8px; background: #ffffff; outline: none; }
    .btn-toggle { padding: 0 16px; border: 1px solid var(--border); background: #ffffff; border-radius: 8px; font-size: 13px; font-weight: 600; color: var(--text-muted); cursor: pointer; }
    
    .report-list { display: flex; flex-direction: column; gap: 14px; }
    details.item { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; box-shadow: 0 1px 2px rgba(0,0,0,0.03); }
    details.item.inhibitor { border-left: 6px solid var(--color-inhibitor); }
    details.item.high { border-left: 6px solid var(--color-high); }
    details.item.medium { border-left: 6px solid var(--color-medium); }
    details.item.low { border-left: 6px solid var(--color-low); }
    details.item.info { border-left: 6px solid var(--color-info); }
    
    summary.item-summary { padding: 16px 20px; display: flex; align-items: center; justify-content: space-between; cursor: pointer; user-select: none; background: #ffffff; }
    summary.item-summary:hover { background: #f8fafc; }
    .summary-left { display: flex; align-items: center; gap: 14px; flex: 1; }
    .pill { display: inline-block; padding: 3px 9px; border-radius: 4px; font-size: 11px; font-weight: 700; text-transform: uppercase; }
    .pill-inhibitor { background: #ffe4e6; color: var(--color-inhibitor); }
    .pill-high { background: #ffedd5; color: var(--color-high); }
    .pill-medium { background: #fef3c7; color: var(--color-medium); }
    .pill-low { background: #dbeafe; color: var(--color-low); }
    .pill-info { background: #d1fae5; color: var(--color-info); }
    .item-title { font-size: 15px; font-weight: 600; }
    .arrow-icon { color: var(--text-muted); font-size: 14px; font-weight: bold; }
    details[open] summary.item-summary { border-bottom: 1px solid var(--border); }
    
    .item-body { padding: 22px 24px; font-size: 14px; color: #334155; }
    .item-description { white-space: pre-wrap; background: #f8fafc; padding: 14px 18px; border-radius: 6px; border: 1px solid #e2e8f0; margin-bottom: 16px; font-size: 13.5px; }
    
    .code-container { position: relative; background: #0f172a; border-radius: 6px; padding: 14px 16px; margin-top: 10px; }
    .code-container pre { color: #e2e8f0; font-family: monospace; font-size: 13px; margin: 0; white-space: pre-wrap; word-break: break-all; }
    .copy-btn { position: absolute; top: 8px; right: 8px; background: rgba(255,255,255,0.15); border: 1px solid rgba(255,255,255,0.2); color: #fff; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; }
    .footer { margin-top: 40px; text-align: center; font-size: 12px; color: var(--text-muted); }
  </style>
</head>
<body>
<div class="container">
  <header class="header">
    <div>
      <h1>Red Hat Leapp Pre-upgrade Assessment & Remediation - """ + escape_html(hostname) + """</h1>
      <div class="subtitle">System: <strong>""" + escape_html(hostname) + """</strong> &bull; Generated: <strong>""" + now_str + """</strong></div>
    </div>
    <div class="badge">RHEL """ + escape_html(curr_major) + """ &rarr; RHEL """ + escape_html(target_major) + """</div>
  </header>

  <div class="generator-card">
    <div class="generator-header">
      <div class="generator-title">&#9889; Generated Remediation Script: <code>remediation_answer.sh</code></div>
      <div class="generator-badge">Ready for Execution</div>
    </div>
    <p style="font-size:13.5px; color:#475569; margin-bottom:12px;">
      This script was automatically compiled by scanning discovered dialogs (<code>answerfile</code>) and inhibitor findings. You can execute it directly on the server to apply all required <code>leapp answer</code> directives at once:
    </p>
    <div class="code-container">
      <button class="copy-btn" onclick="copyText('exec_remediation_cmd', this)">Copy Run Command</button>
      <pre id="exec_remediation_cmd">bash """ + escape_html(out_remediation_sh) + """</pre>
    </div>
    <p style="font-size:12px; font-weight:600; color:#64748b; margin-top:14px; margin-bottom:6px;">Embedded Script Contents:</p>
    <div class="code-container">
      <button class="copy-btn" onclick="copyText('raw_sh_content', this)">Copy Entire Script</button>
      <pre id="raw_sh_content">""" + escape_html(sh_content_raw) + """</pre>
    </div>
  </div>
"""

if counts['inhibitor'] > 0:
    html_doc += """
  <div class="inhibitor-alert">
    <div class="inhibitor-alert-text">&#9888; Upgrade Blocked: <strong>""" + str(counts['inhibitor']) + """ inhibitor(s)</strong> detected. Run <code>remediation_answer.sh</code> to clear blockers.</div>
    <button class="btn-toggle" onclick="filterReport('inhibitor')">View Inhibitors Only</button>
  </div>
"""

html_doc += """
  <section class="metrics-grid">
    <div class="metric-card" onclick="filterReport('all')"><div class="metric-label">Total Findings</div><div class="metric-value">""" + str(len(entries)) + """</div></div>
    <div class="metric-card" onclick="filterReport('inhibitor')"><div class="metric-label">Inhibitors</div><div class="metric-value val-inhibitor">""" + str(counts['inhibitor']) + """</div></div>
    <div class="metric-card" onclick="filterReport('high')"><div class="metric-label">High Risk</div><div class="metric-value val-high">""" + str(counts['high']) + """</div></div>
    <div class="metric-card" onclick="filterReport('medium')"><div class="metric-label">Medium Risk</div><div class="metric-value val-medium">""" + str(counts['medium']) + """</div></div>
    <div class="metric-card" onclick="filterReport('low')"><div class="metric-label">Low Risk</div><div class="metric-value val-low">""" + str(counts['low']) + """</div></div>
    <div class="metric-card" onclick="filterReport('info')"><div class="metric-label">Info</div><div class="metric-value val-info">""" + str(counts['info']) + """</div></div>
  </section>

  <div class="toolbar">
    <input type="text" id="filterInput" class="search-input" placeholder="Search findings, modules, commands..." onkeyup="filterReport()">
    <button class="btn-toggle" onclick="toggleAll(true)">Expand All</button>
    <button class="btn-toggle" onclick="toggleAll(false)">Collapse All</button>
  </div>

  <main class="report-list" id="findingsList">
"""

entry_id = 0
for item in entries:
    entry_id += 1
    sev = item["severity"]
    title_esc = escape_html(item["title"])
    summary_esc = escape_html(item["summary"])
    is_inhibitor = (sev == "inhibitor")

    cmd_block = ""
    if item["commands"]:
        cmd_esc = escape_html(item["commands"])
        cmd_block = """
        <div style="margin-top:14px;">
          <strong style="font-size:12.5px; color:#1e293b;">Recommended Action / Answer:</strong>
          <div class="code-container">
            <button class="copy-btn" onclick="copyText('code_""" + str(entry_id) + """', this)">Copy</button>
            <pre id="code_""" + str(entry_id) + """">""" + cmd_esc + """</pre>
          </div>
        </div>
"""

    open_attr = 'open' if is_inhibitor else ''
    html_doc += """
    <details class="item """ + sev + """" data-sev=\"""" + sev + """\" """ + open_attr + """>
      <summary class="item-summary">
        <div class="summary-left">
          <span class="pill pill-""" + sev + """\">""" + sev + """</span>
          <span class="item-title">""" + title_esc + """</span>
        </div>
        <div class="arrow-icon">&#9656;</div>
      </summary>
      <div class="item-body">
        <div class="item-description">""" + summary_esc + """</div>
        """ + cmd_block + """
      </div>
    </details>
"""

html_doc += """
  </main>
  <footer class="footer">Pre-upgrade assessment report &bull; Red Hat Leapp Upgrade Manager</footer>
</div>
<script>
let currentSeverity = 'all';
function filterReport(sev) {
  if (sev !== undefined) currentSeverity = sev;
  const q = document.getElementById('filterInput').value.toLowerCase();
  document.querySelectorAll('.item').forEach(el => {
    const matchSev = (currentSeverity === 'all' || el.getAttribute('data-sev') === currentSeverity);
    const matchTxt = el.textContent.toLowerCase().includes(q);
    el.style.display = (matchSev && matchTxt) ? 'block' : 'none';
  });
}
function toggleAll(openState) { document.querySelectorAll('.item').forEach(el => el.open = openState); }
function copyText(id, btn) {
  const el = document.getElementById(id);
  if (!el) return;
  navigator.clipboard.writeText(el.innerText).then(() => {
    const o = btn.innerText; btn.innerText = "Copied!"; setTimeout(() => { btn.innerText = o; }, 2000);
  });
}
</script>
</body>
</html>
"""

with open(out_html, 'w') as f:
    f.write(html_doc)

EOF
}

# ------------------------------------------------------------------------------
# Action: pre-upgrade
# ------------------------------------------------------------------------------
run_pre_upgrade() {
    if [[ "$CURRENT_MAJOR" -eq 9 ]]; then
        echo "[ERROR] System is on RHEL 9. No further Leapp path configured." >&2
        exit 1
    fi
    confirm_run "pre-upgrade"

    echo "[INFO] Running 'leapp preupgrade'..."
    leapp preupgrade || true

    mkdir -p "${PRE_DIR}"
    echo "[INFO] Created pre-upgrade artifacts directory: ${PRE_DIR}"

    echo "[INFO] Compiling visual HTML pre-upgrade report & remediation_answer.sh..."
    generate_pre_html_report

    echo "[INFO] Archiving pre-upgrade artifacts..."
    [[ -f /var/log/leapp/answerfile ]] && cp -v /var/log/leapp/answerfile "${PRE_DIR}/" || true
    [[ -f /var/log/leapp/leapp-report.txt ]] && cp -v /var/log/leapp/leapp-report.txt "${PRE_DIR}/" || true
    [[ -f /var/log/leapp/leapp-report.json ]] && cp -v /var/log/leapp/leapp-report.json "${PRE_DIR}/" || true
    [[ -f /var/log/leapp/leapp-preupgrade.log ]] && cp -v /var/log/leapp/leapp-preupgrade.log "${PRE_DIR}/" || true

    # Fix ownership to non-root user
    chown_to_real_user "${PRE_DIR}"

    echo ""
    echo "================================================================================"
    echo " [SUMMARY] Pre-upgrade assessment completed."
    echo " Artifacts Directory   : ${PRE_DIR}"
    echo " Artifacts Owner       : ${REAL_USER}:${REAL_GROUP}"
    echo " Interactive HTML      : ${PRE_HTML}"
    echo " Remediation Script    : ${REMEDIATION_SH}"
    echo ""
    echo " To resolve all inhibitors and register all leapp answers automatically, run:"
    echo "   # bash ${REMEDIATION_SH}"
    echo "================================================================================"
}

# ------------------------------------------------------------------------------
# Action: upgrade
# ------------------------------------------------------------------------------
run_upgrade() {
    if [[ "$CURRENT_MAJOR" -eq 9 ]]; then
        echo "[ERROR] System is on RHEL 9. Upgrade already accomplished." >&2
        exit 1
    fi
    confirm_run "upgrade"

    local latest_rem
    latest_rem=$(find "${SCRIPT_DIR}" -maxdepth 2 -name "remediation_answer.sh" | sort -r | head -n1 || true)
    if [[ -n "$latest_rem" && -f "$latest_rem" ]]; then
        echo ""
        echo "[NOTICE] Found auto-generated remediation script:"
        echo "         ${latest_rem}"
        read -rp "Do you want to run this remediation script to resolve inhibitors prior to upgrade? [Y/n]: " run_ans
        if [[ "$run_ans" =~ ^[yY](es)?$ || -z "$run_ans" ]]; then
            echo "[INFO] Executing remediation script..."
            bash "${latest_rem}"
        fi
    fi

    echo ""
    echo "********************************************************************************"
    echo " [WARNING] CRITICAL OPERATION IN-PROGRESS"
    echo " You are about to initiate the actual OS in-place migration."
    echo " System packages and kernel will be upgraded."
    echo " Policy Note: Third-party packages, RPMs, and repos are NOT removed."
    echo " A system reboot will be required immediately upon completion."
    echo "********************************************************************************"
    echo ""

    read -rp "TYPE 'UPGRADE' TO CONFIRM EXECUTION: " final_confirm
    if [[ "$final_confirm" != "UPGRADE" ]]; then
        echo "[INFO] Double-confirmation failed or cancelled. Upgrade will not run."
        exit 0
    fi

    echo "[INFO] Initiating 'leapp upgrade'..."
    leapp upgrade

    echo ""
    echo "================================================================================"
    echo " [SUCCESS] Leapp upgrade package transaction completed."
    echo " Reboot the system now to execute the second stage of the upgrade:"
    echo "   # reboot"
    echo ""
    echo " After rebooting into the new OS, run:"
    echo "   # $0 post-upgrade"
    echo " to verify third-party packages, SELinux, repositories, and configurations."
    echo "================================================================================"
}

# ------------------------------------------------------------------------------
# Action: post-upgrade (Audit and Verification Report)
# ------------------------------------------------------------------------------
run_post_upgrade() {
    confirm_run "post-upgrade"

    mkdir -p "${POST_DIR}"
    echo "[INFO] Created post-upgrade artifacts directory: ${POST_DIR}"

    echo "[INFO] Collecting system state, third-party RPMs, and repository statuses..."

    local kernel_ver
    kernel_ver=$(uname -r)

    local old_dist_pkgs_file="${POST_DIR}/third_party_and_legacy_rpms.txt"
    if [[ "$CURRENT_MAJOR" -ge 8 ]]; then
        rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} | %{VENDOR} | %{PACKAGER}\n" | grep -E "\.el$((CURRENT_MAJOR - 1))" > "${old_dist_pkgs_file}" || true
    fi

    local third_party_rpms_file="${POST_DIR}/non_redhat_packages.txt"
    rpm -qa --qf "%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} | %{SIGPGP:pgpsig} | %{VENDOR}\n" | grep -iv "Red Hat" > "${third_party_rpms_file}" || true

    local repos_status_file="${POST_DIR}/repositories_status.txt"
    if command -v dnf >/dev/null 2>&1; then
        dnf repolist all > "${repos_status_file}" 2>&1 || true
    else
        yum repolist all > "${repos_status_file}" 2>&1 || true
    fi

    local selinux_stat="Disabled"
    if command -v getenforce >/dev/null 2>&1; then
        selinux_stat=$(getenforce || echo "Unknown")
    fi

    local config_diff_file="${POST_DIR}/configuration_rpmnew_rpmsave.txt"
    find /etc -name "*.rpmnew" -o -name "*.rpmsave" > "${config_diff_file}" 2>/dev/null || true

    [[ -f /var/log/leapp/leapp-upgrade.log ]] && cp -v /var/log/leapp/leapp-upgrade.log "${POST_DIR}/" || true

    echo "[INFO] Compiling post-upgrade verification HTML dashboard using ${PYTHON_BIN}..."

    "$PYTHON_BIN" - "$POST_HTML" "$HOSTNAME_VAL" "$RELEASE_TEXT" "$kernel_ver" "$selinux_stat" \
                   "${old_dist_pkgs_file}" "${third_party_rpms_file}" "${repos_status_file}" "${config_diff_file}" << 'EOF'
import sys
import os
import datetime

try:
    import html
    def escape_html(text): return html.escape(str(text))
except ImportError:
    import cgi
    def escape_html(text): return cgi.escape(str(text), quote=True)

out_html, hostname, release_text, kernel_ver, selinux_stat, old_pkgs_path, non_rh_path, repos_path, configs_path = sys.argv[1:10]

def read_lines(filepath):
    if os.path.exists(filepath):
        with open(filepath, 'r') as f:
            return [l.strip() for l in f if l.strip()]
    return []

old_pkgs = read_lines(old_pkgs_path)
non_rh_pkgs = read_lines(non_rh_path)
repos_lines = read_lines(repos_path)
config_files = read_lines(configs_path)

now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

html_doc = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Post-Upgrade Verification & Configuration Report - """ + escape_html(hostname) + """</title>
  <style>
    :root {
      --bg: #0f172a; --card-bg: #ffffff; --page-bg: #f8fafc; --text-main: #0f172a;
      --text-muted: #475569; --border: #e2e8f0; --accent: #0284c7; --success: #059669;
      --warning: #d97706; --danger: #dc2626;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--page-bg); color: var(--text-main); padding: 32px 20px; }
    .container { max-width: 1240px; margin: 0 auto; }
    .header { background: linear-gradient(135deg, #047857 0%, #064e3b 100%); color: #ffffff; padding: 28px 32px; border-radius: 12px; display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
    .header h1 { font-size: 22px; font-weight: 700; margin-bottom: 4px; }
    .header .subtitle { color: #a7f3d0; font-size: 14px; }
    .badge { background: rgba(255,255,255,0.2); border: 1px solid rgba(255,255,255,0.3); padding: 8px 18px; border-radius: 9999px; font-size: 14px; font-weight: 600; }
    
    .metrics-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 24px; }
    .metric-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px; padding: 18px 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
    .metric-label { font-size: 11px; font-weight: 700; text-transform: uppercase; color: var(--text-muted); }
    .metric-value { font-size: 22px; font-weight: 700; margin-top: 4px; }

    .section-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 20px; overflow: hidden; box-shadow: 0 1px 2px rgba(0,0,0,0.04); }
    .section-header { padding: 16px 20px; background: #f8fafc; border-bottom: 1px solid var(--border); font-size: 16px; font-weight: 700; display: flex; justify-content: space-between; align-items: center; }
    .section-body { padding: 20px; font-size: 14px; }
    .status-pill { display: inline-block; padding: 3px 10px; border-radius: 9999px; font-size: 11px; font-weight: 700; text-transform: uppercase; }
    .pill-safe { background: #d1fae5; color: #065f46; }
    .pill-warn { background: #fef3c7; color: #92400e; }
    
    .code-container { background: #0f172a; border-radius: 6px; padding: 14px 16px; margin-top: 10px; position: relative; }
    .code-container pre { color: #e2e8f0; font-family: monospace; font-size: 13px; margin: 0; white-space: pre-wrap; word-break: break-all; }
    .copy-btn { position: absolute; top: 8px; right: 8px; background: rgba(255,255,255,0.15); border: 1px solid rgba(255,255,255,0.2); color: #fff; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; }
    
    .table-container { overflow-x: auto; margin-top: 10px; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--border); }
    th { background: #f1f5f9; color: var(--text-muted); font-size: 11px; text-transform: uppercase; }
    
    .task-item { background: #f8fafc; border: 1px solid var(--border); border-left: 4px solid #0284c7; padding: 14px 18px; border-radius: 6px; margin-bottom: 12px; }
    .task-title { font-weight: 600; margin-bottom: 4px; }
    .task-desc { font-size: 13px; color: var(--text-muted); margin-bottom: 8px; }
    .footer { margin-top: 40px; text-align: center; font-size: 12px; color: var(--text-muted); }
  </style>
</head>
<body>
<div class="container">
  <header class="header">
    <div>
      <h1>Post-Upgrade Verification & Configuration Report - """ + escape_html(hostname) + """</h1>
      <div class="subtitle">System: <strong>""" + escape_html(hostname) + """</strong> &bull; Generated: <strong>""" + now_str + """</strong></div>
    </div>
    <div class="badge">""" + escape_html(release_text) + """</div>
  </header>

  <section class="metrics-grid">
    <div class="metric-card">
      <div class="metric-label">Active Running Kernel</div>
      <div class="metric-value" style="font-size:17px; word-break:break-all;">""" + escape_html(kernel_ver) + """</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">Third-Party / Non-RH RPMs Preserved</div>
      <div class="metric-value" style="color:var(--success);">""" + str(len(non_rh_pkgs)) + """</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">Previous Dist RPMs Present</div>
      <div class="metric-value" style="color:var(--warning);">""" + str(len(old_pkgs)) + """</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">Pending Config Merges (.rpmnew)</div>
      <div class="metric-value">""" + str(len(config_files)) + """</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">SELinux Mode</div>
      <div class="metric-value" style="color:""" + ('#dc2626' if selinux_stat.lower() == 'permissive' else '#059669') + """;">""" + escape_html(selinux_stat) + """</div>
    </div>
  </section>

  <!-- Section 1: Required Post-Upgrade Tasks -->
  <div class="section-card">
    <div class="section-header">
      <span>&#128203; Required Post-Upgrade Administrative Tasks</span>
      <span class="status-pill pill-warn">Action Checklist</span>
    </div>
    <div class="section-body">
      <div class="task-item">
        <div class="task-title">1. Re-enable SELinux Enforcing Mode</div>
        <div class="task-desc">Leapp sets SELinux to Permissive mode during upgrades to avoid boot blocking. Verify SELinux logs, then revert to Enforcing.</div>
        <div class="code-container">
          <button class="copy-btn" onclick="copyText('selinux_cmd', this)">Copy</button>
          <pre id="selinux_cmd">sed -i 's/^SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
setenforce 1</pre>
        </div>
      </div>

      <div class="task-item">
        <div class="task-title">2. Set Default Python Alternative</div>
        <div class="task-desc">RHEL 8 does not map 'python' by default. Set it to Python 3 so custom commands or legacy scripts run cleanly.</div>
        <div class="code-container">
          <button class="copy-btn" onclick="copyText('python_cmd', this)">Copy</button>
          <pre id="python_cmd">alternatives --set python /usr/bin/python3</pre>
        </div>
      </div>

      <div class="task-item">
        <div class="task-title">3. Review / Merge .rpmnew and .rpmsave Configuration Files</div>
        <div class="task-desc">RHEL upgrades preserve your existing service configs, saving new distribution templates as .rpmnew. Merge desired options using rpmconf.</div>
        <div class="code-container">
          <button class="copy-btn" onclick="copyText('rpmconf_cmd', this)">Copy</button>
          <pre id="rpmconf_cmd">dnf install -y rpmconf
rpmconf -a</pre>
        </div>
      </div>

      <div class="task-item">
        <div class="task-title">4. Verify & Re-enable Third-Party Repositories</div>
        <div class="task-desc">Leapp disables custom/third-party repos during migration to ensure solver compatibility. They remain intact under /etc/yum.repos.d/ and can be re-enabled without removal.</div>
        <div class="code-container">
          <button class="copy-btn" onclick="copyText('repo_cmd', this)">Copy</button>
          <pre id="repo_cmd"># Inspect preserved repo configurations:
ls -la /etc/yum.repos.d/
# Enable specific third-party repositories as required:
dnf config-manager --set-enabled &lt;repo_id&gt;</pre>
        </div>
      </div>
    </div>
  </div>

  <!-- Section 2: Preserved Third-Party Packages -->
  <div class="section-card">
    <div class="section-header">
      <span>&#128230; Preserved Non-Red Hat / Third-Party Packages (""" + str(len(non_rh_pkgs)) + """)</span>
      <span class="status-pill pill-safe">Retained Intact</span>
    </div>
    <div class="section-body">
      <p style="margin-bottom:12px; color:var(--text-muted);">The following packages are installed and were not deleted. They do not carry Red Hat official signatures and can remain running or updated via their vendor repositories:</p>
      <div class="table-container">
        <table>
          <thead><tr><th>Package Name, Version & Arch</th><th>Vendor / Signer</th></tr></thead>
          <tbody>
"""

if non_rh_pkgs:
    for line in non_rh_pkgs[:50]:
        parts = line.split("|")
        pname = parts[0].strip() if len(parts) > 0 else line
        vendor = parts[-1].strip() if len(parts) > 1 else "Third-Party"
        html_doc += "<tr><td>" + escape_html(pname) + "</td><td>" + escape_html(vendor) + "</td></tr>\n"
    if len(non_rh_pkgs) > 50:
        html_doc += "<tr><td colspan='2'><em>...and " + str(len(non_rh_pkgs) - 50) + " more. Full list in non_redhat_packages.txt</em></td></tr>"
else:
    html_doc += "<tr><td colspan='2'>No third-party packages detected. All installed RPMs are Red Hat signed.</td></tr>"

html_doc += """
          </tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- Section 3: Configuration Files Pending Review -->
  <div class="section-card">
    <div class="section-header">
      <span>&#9881; Config Files Saved During Upgrade (.rpmnew / .rpmsave) (""" + str(len(config_files)) + """)</span>
      <span class="status-pill pill-warn">Review Needed</span>
    </div>
    <div class="section-body">
      <p style="margin-bottom:12px; color:var(--text-muted);">These files were created to protect your custom configurations from being overwritten:</p>
"""

if config_files:
    html_doc += "<ul style='padding-left:20px; font-family:monospace; font-size:13px;'>"
    for c in config_files:
        html_doc += "<li>" + escape_html(c) + "</li>"
    html_doc += "</ul>"
else:
    html_doc += "<p>No .rpmnew or .rpmsave configuration files found under /etc.</p>"

html_doc += """
    </div>
  </div>

  <footer class="footer">Post-upgrade verification report &bull; Red Hat Leapp Upgrade Manager</footer>
</div>

<script>
function copyText(id, btn) {
  const el = document.getElementById(id);
  if (!el) return;
  navigator.clipboard.writeText(el.innerText).then(() => {
    const o = btn.innerText; btn.innerText = "Copied!"; setTimeout(() => { btn.innerText = o; }, 2000);
  });
}
</script>
</body>
</html>
"""

with open(out_html, 'w') as f:
    f.write(html_doc)
EOF

    # Fix ownership of created artifacts directory to the original invoking non-root user
    chown_to_real_user "${POST_DIR}"

    echo ""
    echo "================================================================================"
    echo " [SUCCESS] Post-upgrade verification report created."
    echo " Artifacts Directory : ${POST_DIR}"
    echo " Artifacts Owner     : ${REAL_USER}:${REAL_GROUP}"
    echo " Interactive HTML    : ${POST_HTML}"
    echo ""
    echo " Open the HTML file to inspect preserved third-party packages and configuration tasks."
    echo "================================================================================"
}

# ------------------------------------------------------------------------------
# Usage Help
# ------------------------------------------------------------------------------
usage() {
    echo "Usage: $0 {install-pre-req|pre-upgrade|upgrade|post-upgrade}"
    echo ""
    echo "Parameters:"
    echo "  install-pre-req : Install Leapp tools and migration modules"
    echo "  pre-upgrade     : Run pre-upgrade inspection, collect artifacts, and generate report & remediation script"
    echo "  upgrade         : Trigger actual system in-place upgrade (prompts to auto-run remediation_answer.sh)"
    echo "  post-upgrade    : Run post-reboot verification HTML report for configurations & preserved third-party RPMs"
    exit 1
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
case "${1:-}" in
    install-pre-req)
        install_pre_req
        ;;
    pre-upgrade)
        run_pre_upgrade
        ;;
    upgrade)
        run_upgrade
        ;;
    post-upgrade)
        run_post_upgrade
        ;;
    *)
        usage
        ;;
esac
