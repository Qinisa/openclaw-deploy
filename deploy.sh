#!/usr/bin/env bash
# ============================================================================
# OpenClaw VPS Bootstrap Script
# Hardens a fresh Hetzner Ubuntu VPS and installs OpenClaw
#
# Usage (as root on a fresh VPS):
#   curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/deploy.sh | bash
#   OR
#   bash deploy.sh
#
# What it does:
#   1. Creates 'clawdbot' user with SSH key auth
#   2. Hardens SSH (no root login, no passwords)
#   3. Configures UFW firewall
#   4. Installs fail2ban
#   5. Disables unnecessary services
#   6. Applies kernel hardening
#   7. Installs Node.js 22 LTS via NodeSource
#   8. Installs OpenClaw globally
#   9. Installs Chrome (headless)
#  10. Verifies everything
#  13. Prompts user to log in as clawdbot and run: openclaw onboard --install-daemon
#
# Designed for: Ubuntu 24.04 LTS on Hetzner Cloud
# Author: CrawBot 🦞
# ============================================================================

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${CYAN}[openclaw]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    err "Usage: sudo bash deploy.sh"
    exit 1
fi

if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu. Proceeding anyway..."
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║    OpenClaw VPS Bootstrap & Hardening        ║${NC}"
echo -e "${CYAN}║    Designed for Hetzner + Ubuntu 24.04       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""

# --- Configuration ---
USERNAME="clawdbot"
NODE_MAJOR=22

# Prompt for SSH public key
if [[ -z "${SSH_PUBKEY:-}" ]]; then
    echo -e "${CYAN}Paste the SSH public key for the '${USERNAME}' user:${NC}"
    read -r SSH_PUBKEY
fi

if [[ -z "$SSH_PUBKEY" ]]; then
    err "SSH public key is required."
    exit 1
fi

# ============================================================================
# PHASE 1: User Setup
# ============================================================================
log "Phase 1: Creating user '${USERNAME}'..."

if id "$USERNAME" &>/dev/null; then
    warn "User '${USERNAME}' already exists, skipping creation."
else
    adduser --disabled-password --gecos "" "$USERNAME"
    ok "User '${USERNAME}' created."
fi

# Configure passwordless sudo for clawdbot
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"
chmod 440 "/etc/sudoers.d/${USERNAME}"
ok "Passwordless sudo configured for '${USERNAME}'."

# SSH key
mkdir -p "/home/${USERNAME}/.ssh"
chmod 700 "/home/${USERNAME}/.ssh"

# Append key if not already present
if ! grep -qF "$SSH_PUBKEY" "/home/${USERNAME}/.ssh/authorized_keys" 2>/dev/null; then
    echo "$SSH_PUBKEY" >> "/home/${USERNAME}/.ssh/authorized_keys"
fi
chmod 600 "/home/${USERNAME}/.ssh/authorized_keys"
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.ssh"
ok "SSH key configured."

# ============================================================================
# PHASE 2: SSH Hardening
# ============================================================================
log "Phase 2: Hardening SSH..."

# Disable root login
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

# Disable password authentication in main config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Also enforce via sshd_config.d drop-in (belt and suspenders)
cat > /etc/ssh/sshd_config.d/hardening.conf << 'SSHEOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
SSHEOF

# Remove cloud-init SSH override if present (often re-enables password auth)
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf

systemctl restart ssh
ok "SSH hardened: root login disabled, password auth disabled, key-only access."

# ============================================================================
# PHASE 3: Firewall
# ============================================================================
log "Phase 3: Configuring firewall..."

apt-get update -qq
apt-get install -y -qq ufw > /dev/null 2>&1

# Set defaults before enabling — deny first, then whitelist
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "SSH"

# Enable (--force skips interactive prompt)
ufw --force enable
ok "UFW enabled: default deny incoming, SSH (22/tcp) allowed."

# ============================================================================
# PHASE 4: Fail2ban
# ============================================================================
log "Phase 4: Installing fail2ban..."

apt-get install -y -qq fail2ban > /dev/null 2>&1

cat > /etc/fail2ban/jail.local << 'F2BEOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
F2BEOF

systemctl enable --now fail2ban > /dev/null 2>&1
ok "Fail2ban installed and configured (3 retries, 1h ban)."

# ============================================================================
# PHASE 5: Disable Unnecessary Services
# ============================================================================
log "Phase 5: Disabling unnecessary services..."

# CUPS (printing) — often enabled by default
systemctl disable --now snap.cups.cupsd snap.cups.cups-browsed 2>/dev/null || true
ok "Unnecessary services disabled."

# ============================================================================
# PHASE 6: Kernel Hardening
# ============================================================================
log "Phase 6: Applying kernel hardening..."

cat > /etc/sysctl.d/99-hardening.conf << 'KERNEOF'
# Disable ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Enable SYN flood protection
net.ipv4.tcp_syncookies = 1

# Disable IP forwarding (not a router)
net.ipv4.ip_forward = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
KERNEOF

sysctl --system > /dev/null 2>&1
ok "Kernel hardened."

# ============================================================================
# PHASE 7: System Updates
# ============================================================================
log "Phase 7: Applying system updates..."

apt-get upgrade -y -qq > /dev/null 2>&1
apt-get install -y -qq curl git build-essential > /dev/null 2>&1

# Install unattended-upgrades for automatic security patches
apt-get install -y -qq unattended-upgrades > /dev/null 2>&1
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
ok "System updated, unattended-upgrades enabled."

# ============================================================================
# PHASE 8: Install Node.js
# ============================================================================
log "Phase 8: Installing Node.js ${NODE_MAJOR}..."

if command -v node &>/dev/null && node -v | grep -q "v${NODE_MAJOR}"; then
    ok "Node.js $(node -v) already installed."
else
    # NodeSource setup
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - > /dev/null 2>&1
    apt-get install -y -qq nodejs > /dev/null 2>&1
    ok "Node.js $(node -v) installed."
fi

# ============================================================================
# PHASE 9: Install OpenClaw
# ============================================================================
log "Phase 9: Installing OpenClaw..."

# Set up npm global directory for clawdbot user (no sudo needed for npm)
sudo -u "$USERNAME" bash << 'NPMEOF'
mkdir -p ~/.npm-global
npm config set prefix "$HOME/.npm-global"

# Add to PATH if not already there
if ! grep -q ".npm-global/bin" ~/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
fi
export PATH="$HOME/.npm-global/bin:$PATH"

# Install OpenClaw
npm install -g openclaw
NPMEOF

ok "OpenClaw installed: $(sudo -u "$USERNAME" bash -c 'export PATH="$HOME/.npm-global/bin:$PATH" && openclaw --version')"

# ============================================================================
# PHASE 10: Install Chrome (for browser tools)
# ============================================================================
log "Phase 10: Installing Chrome (headless)..."

if command -v google-chrome &>/dev/null; then
    ok "Chrome already installed."
else
    wget -q -O /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    apt-get install -y -qq /tmp/chrome.deb > /dev/null 2>&1 || apt-get install -y -f -qq > /dev/null 2>&1
    rm -f /tmp/chrome.deb
    ok "Chrome installed."
fi


# ============================================================================
# PHASE 11: Docker Sandboxing (Optional)
# ============================================================================
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  Optional: Docker Sandboxing                            ║${NC}"
echo -e "${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${YELLOW}║                                                          ║${NC}"
echo -e "${YELLOW}║  Sandboxing runs agent tools inside Docker containers    ║${NC}"
echo -e "${YELLOW}║  so rogue commands can't access the host filesystem.     ║${NC}"
echo -e "${YELLOW}║  Your main chat session keeps full host access.          ║${NC}"
echo -e "${YELLOW}║                                                          ║${NC}"
echo -e "${YELLOW}║  ${GREEN}RECOMMENDED for:${YELLOW}                                        ║${NC}"
echo -e "${YELLOW}║    • Multi-user setups (exec teams, shared bots)         ║${NC}"
echo -e "${YELLOW}║    • Bots with access to sensitive credentials           ║${NC}"
echo -e "${YELLOW}║    • Public-facing or large server deployments           ║${NC}"
echo -e "${YELLOW}║                                                          ║${NC}"
echo -e "${YELLOW}║  ${RED}NOT recommended for:${YELLOW}                                    ║${NC}"
echo -e "${YELLOW}║    • Solo dev workflows where the bot needs full         ║${NC}"
echo -e "${YELLOW}║      filesystem access across all channels               ║${NC}"
echo -e "${YELLOW}║    • Software development setups with repo access        ║${NC}"
echo -e "${YELLOW}║                                                          ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "${ENABLE_SANDBOX:-}" == "y" ]]; then
    SETUP_SANDBOX="y"
else
    read -rp "$(echo -e "${CYAN}Enable Docker sandboxing? [y/N]:${NC} ")" SETUP_SANDBOX
fi

if [[ "${SETUP_SANDBOX,,}" == "y" || "${SETUP_SANDBOX,,}" == "yes" ]]; then
    log "Installing Docker and building sandbox image..."

    apt-get install -y -qq ca-certificates curl gnupg > /dev/null 2>&1
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin > /dev/null 2>&1
    ok "Docker installed."

    usermod -aG docker "$USERNAME"
    ok "User '${USERNAME}' added to docker group."

    TMPDIR=$(mktemp -d)
    cat > "$TMPDIR/Dockerfile" << 'DOCKERFILE'
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    python3 \
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox

CMD ["sleep", "infinity"]
DOCKERFILE
    docker build -t "openclaw-sandbox:bookworm-slim" -f "$TMPDIR/Dockerfile" "$TMPDIR" > /dev/null 2>&1
    rm -rf "$TMPDIR"
    ok "Sandbox image built: openclaw-sandbox:bookworm-slim"
    SANDBOX_INSTALLED=true

else
    log "Skipping Docker sandboxing. Enable later with: bash update.sh --sandbox"
fi

# ============================================================================
# PHASE 12: Verification
# ============================================================================
echo ""
log "Phase 12: Running verification checks..."
echo ""

# Run verify.sh from same directory (or download if missing)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/verify.sh" ]]; then
    bash "${SCRIPT_DIR}/verify.sh" || true
else
    curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/verify.sh | bash || true
fi

VPS_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${YELLOW}⚠  Reboot recommended to apply kernel changes:  sudo reboot${NC}"
echo ""
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  NEXT: Complete OpenClaw Setup${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo ""
echo -e "  1. From your local machine, SSH in as the new user:"
echo ""
echo -e "     ${GREEN}ssh ${USERNAME}@${VPS_IP}${NC}"
echo ""
echo -e "  2. Run the OpenClaw onboarding wizard:"
echo ""
echo -e "     ${GREEN}openclaw onboard --install-daemon${NC}"
echo ""
echo -e "  This will configure OpenClaw (API keys, Telegram bot,"
echo -e "  etc.) and install it as a system daemon."

if [[ "${SANDBOX_INSTALLED:-false}" == "true" ]]; then
    echo ""
    echo -e "  3. Enable Docker sandboxing:"
    echo ""
    echo -e "     ${GREEN}bash update.sh --sandbox${NC}"
    echo ""
    echo -e "  This patches the OpenClaw config to sandbox sub-agent"
    echo -e "  and group chat sessions in Docker containers."
fi

echo ""
echo -e "🦞 ${CYAN}Server hardening complete. Log in as ${USERNAME} to finish setup.${NC}"
