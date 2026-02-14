#!/usr/bin/env bash
# ============================================================================
# OpenClaw VPS Maintenance Script
# Updates system packages, OpenClaw, and re-verifies hardening
#
# Usage (as clawdbot user):
#   bash openclaw-update.sh [--openclaw-only] [--system-only] [--verify-only]
#
# Designed for: Ubuntu 24.04 LTS on Hetzner Cloud
# Author: CrawBot 🦞
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${CYAN}[openclaw]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

MODE="${1:-all}"

# --- System Updates ---
if [[ "$MODE" == "all" || "$MODE" == "--system-only" ]]; then
    log "Updating system packages..."
    sudo apt-get update -qq
    sudo apt-get upgrade -y -qq
    ok "System packages updated."
fi

# --- OpenClaw Update ---
if [[ "$MODE" == "all" || "$MODE" == "--openclaw-only" ]]; then
    CURRENT=$(openclaw --version 2>/dev/null || echo "unknown")
    log "Current OpenClaw version: ${CURRENT}"
    log "Updating OpenClaw..."

    npm install -g openclaw@latest
    NEW=$(openclaw --version 2>/dev/null || echo "unknown")

    if [[ "$CURRENT" != "$NEW" ]]; then
        ok "OpenClaw updated: ${CURRENT} → ${NEW}"
        log "Restarting OpenClaw gateway..."
        sudo systemctl restart openclaw
        sleep 3
        if systemctl is-active --quiet openclaw; then
            ok "Gateway restarted successfully."
        else
            err "Gateway failed to start! Check: journalctl -u openclaw -n 50"
        fi
    else
        ok "OpenClaw already at latest version (${CURRENT})."
    fi
fi

# --- Verification ---
if [[ "$MODE" == "all" || "$MODE" == "--verify-only" ]]; then
    echo ""
    log "Running hardening verification..."
    echo ""

    PASS=0
    FAIL=0

    check() {
        if eval "$2" > /dev/null 2>&1; then
            ok "$1"
            ((PASS++))
        else
            err "$1"
            ((FAIL++))
        fi
    }

    check "SSH: root login disabled"    "sudo sshd -T 2>/dev/null | grep -q 'permitrootlogin no'"
    check "SSH: password auth disabled" "sudo sshd -T 2>/dev/null | grep -q 'passwordauthentication no'"
    check "Firewall: UFW active"        "sudo ufw status | grep -q 'Status: active'"
    check "Fail2ban: running"           "systemctl is-active fail2ban"
    check "OpenClaw: running"           "systemctl is-active openclaw"
    check "OpenClaw: version"           "openclaw --version"
    check "Disk: >20% free"            "[[ \$(df / --output=pcent | tail -1 | tr -dc '0-9') -lt 80 ]]"
    check "Memory: <90% used"          "[[ \$(free | awk '/Mem:/{printf \"%.0f\", \$3/\$2*100}') -lt 90 ]]"
    check "No pending reboot"          "! [ -f /var/run/reboot-required ]"

    echo ""
    echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
    echo ""

    if [ -f /var/run/reboot-required ]; then
        warn "System reboot required (kernel or library update pending)."
    fi
fi

echo -e "🦞 ${CYAN}Maintenance complete.${NC}"
