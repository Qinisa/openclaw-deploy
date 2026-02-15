#!/usr/bin/env bash
# OpenClaw VPS Verification Script
# Run standalone or via deploy.sh
# Usage: curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/verify.sh | sudo bash

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

USERNAME="clawdbot"
NODE_MAJOR=22

PASS=0
FAIL=0

check() {
    if eval "$2" > /dev/null 2>&1; then
        ok "$1"
        PASS=$((PASS + 1))
    else
        err "$1"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  OpenClaw VPS Verification${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo ""

check "SSH: root login disabled"    "sshd -T 2>/dev/null | grep -q 'permitrootlogin no'"
check "SSH: password auth disabled" "sshd -T 2>/dev/null | grep -q 'passwordauthentication no'"
check "SSH: pubkey auth enabled"    "sshd -T 2>/dev/null | grep -q 'pubkeyauthentication yes'"
check "Firewall: UFW active"        "ufw status | grep -q 'Status: active'"
check "Firewall: SSH allowed"       "ufw status | grep -q '22/tcp'"
check "Fail2ban: running"           "systemctl is-active fail2ban"
check "Fail2ban: SSH jail active"   "fail2ban-client status sshd"
check "Kernel: SYN cookies enabled" "[[ \$(sysctl -n net.ipv4.tcp_syncookies) == 1 ]]"
check "Node.js: installed"          "node -v | grep -q 'v${NODE_MAJOR}'"
check "OpenClaw: installed"         "sudo -u ${USERNAME} bash -c 'export PATH=\"\$HOME/.npm-global/bin:\$PATH\" && openclaw --version'"
check "Chrome: installed"           "command -v google-chrome"
check "Auto-updates: enabled"       "systemctl is-active unattended-upgrades"

echo ""
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
else
    warn "Some checks failed. Review the output above."
fi

exit $FAIL
