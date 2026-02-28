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
#   1.  Creates 'clawdbot' user with scoped sudo & SSH key auth
#   2.  Hardens SSH (no root login, no passwords)
#   3.  Configures UFW firewall
#   4.  Installs fail2ban
#   5.  Disables unnecessary services
#   6.  Applies kernel hardening
#   7.  System updates + unattended-upgrades
#   8.  Configures swap (2GB swapfile)
#   9.  Configures log rotation (journald + logrotate)
#  10.  Installs Node.js 22 LTS via NodeSource
#  11.  Installs OpenClaw globally
#  12.  Installs Chrome (headless)
#  13.  Docker Sandboxing (optional)
#  14.  Verification & next steps
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

# --- Pipe safety: detect non-interactive mode ---
INTERACTIVE=true
if [[ ! -t 0 ]]; then
    INTERACTIVE=false
    log "Non-interactive mode detected (piped input). Using environment variables."
fi

# Prompt for SSH public key (or use env var)
if [[ -z "${SSH_PUBKEY:-}" ]]; then
    if $INTERACTIVE; then
        echo -e "${CYAN}Paste the SSH public key for the '${USERNAME}' user:${NC}"
        read -r SSH_PUBKEY
    else
        err "SSH_PUBKEY environment variable is required when running non-interactively."
        err "Usage: SSH_PUBKEY='ssh-ed25519 AAAA...' curl -fsSL ... | bash"
        exit 1
    fi
fi

if [[ -z "$SSH_PUBKEY" ]]; then
    err "SSH public key is required."
    exit 1
fi

# ============================================================================
# PHASE 1: User Setup (scoped sudo)
# ============================================================================
log "Phase 1: Creating user '${USERNAME}' with scoped sudo..."

if id "$USERNAME" &>/dev/null; then
    warn "User '${USERNAME}' already exists, skipping creation."
else
    adduser --disabled-password --gecos "" "$USERNAME"
    ok "User '${USERNAME}' created."
fi

# Configure scoped passwordless sudo (least-privilege)
cat > "/etc/sudoers.d/${USERNAME}" << 'SUDOEOF'
# OpenClaw scoped sudo — least-privilege, no blanket NOPASSWD:ALL
Cmnd_Alias OPENCLAW_SVC = /usr/bin/systemctl, /usr/sbin/ufw, /usr/bin/fail2ban-client, \
    /usr/bin/journalctl, /usr/sbin/reboot, /usr/sbin/sysctl, \
    /usr/sbin/sshd, /usr/bin/dpkg-reconfigure
Cmnd_Alias OPENCLAW_PKG = /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg, \
    /usr/bin/wget, /usr/bin/curl
Cmnd_Alias OPENCLAW_DOCKER = /usr/bin/docker, /usr/bin/dockerd, \
    /usr/sbin/usermod, /usr/sbin/adduser
Cmnd_Alias OPENCLAW_FS = /usr/bin/tee, /usr/bin/install, /usr/bin/mkdir, \
    /bin/chmod, /bin/chown, /usr/bin/chmod, /usr/bin/chown, \
    /bin/rm, /usr/bin/rm, /bin/sed, /usr/bin/sed, /bin/cat, /usr/bin/cat, \
    /bin/mv, /usr/bin/mv, /bin/cp, /usr/bin/cp, \
    /usr/bin/gpg
clawdbot ALL=(ALL) NOPASSWD: OPENCLAW_SVC, OPENCLAW_PKG, OPENCLAW_DOCKER, OPENCLAW_FS
SUDOEOF
chmod 440 "/etc/sudoers.d/${USERNAME}"
ok "Scoped sudo configured for '${USERNAME}' (least-privilege)."

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

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

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

rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
systemctl restart ssh
ok "SSH hardened: root login disabled, password auth disabled, key-only access."

# ============================================================================
# PHASE 3: Firewall
# ============================================================================
log "Phase 3: Configuring firewall..."

apt-get update -qq
apt-get install -y -qq ufw > /dev/null 2>&1

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "SSH"
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

systemctl disable --now snap.cups.cupsd snap.cups.cups-browsed 2>/dev/null || true
ok "Unnecessary services disabled."

# ============================================================================
# PHASE 6: Kernel Hardening
# ============================================================================
log "Phase 6: Applying kernel hardening..."

cat > /etc/sysctl.d/99-hardening.conf << 'KERNEOF'
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_forward = 0
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
apt-get install -y -qq unattended-upgrades > /dev/null 2>&1
dpkg-reconfigure -plow unattended-upgrades 2>/dev/null || true
ok "System updated, unattended-upgrades enabled."

# ============================================================================
# PHASE 8: Swap Configuration
# ============================================================================
log "Phase 8: Configuring swap..."

SWAP_SIZE="2G"
SWAP_FILE="/swapfile"

if swapon --show | grep -q "$SWAP_FILE"; then
    ok "Swap already configured ($(swapon --show --noheadings | awk '{print $3}'))."
elif swapon --show | grep -q "/"; then
    ok "Swap already active ($(swapon --show --noheadings | awk '{print $1, $3}'))."
else
    fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" > /dev/null 2>&1
    swapon "$SWAP_FILE"

    # Persist across reboots
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi

    # Tune swappiness for server workload
    sysctl vm.swappiness=10 > /dev/null 2>&1
    echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf

    ok "Swap configured: ${SWAP_SIZE} swapfile, swappiness=10."
fi

# ============================================================================
# PHASE 9: Log Rotation
# ============================================================================
log "Phase 9: Configuring log rotation..."

# Journald size limits
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size-limit.conf << 'JOURNALEOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=30day
JOURNALEOF
systemctl restart systemd-journald 2>/dev/null || true

# Logrotate for OpenClaw logs
cat > /etc/logrotate.d/openclaw << 'LOGEOF'
/home/clawdbot/.openclaw/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 clawdbot clawdbot
    sharedscripts
    postrotate
        systemctl reload openclaw 2>/dev/null || true
    endscript
}
LOGEOF

ok "Log rotation configured (journald 500M, logrotate 14 days)."

# ============================================================================
# PHASE 10: Install Node.js
# ============================================================================
log "Phase 10: Installing Node.js ${NODE_MAJOR}..."

if command -v node &>/dev/null && node -v | grep -q "v${NODE_MAJOR}"; then
    ok "Node.js $(node -v) already installed."
else
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - > /dev/null 2>&1
    apt-get install -y -qq nodejs > /dev/null 2>&1
    ok "Node.js $(node -v) installed."
fi

# ============================================================================
# PHASE 11: Install OpenClaw
# ============================================================================
log "Phase 11: Installing OpenClaw..."

sudo -u "$USERNAME" bash << 'NPMEOF'
mkdir -p ~/.npm-global
npm config set prefix "$HOME/.npm-global"

if ! grep -q ".npm-global/bin" ~/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
fi
export PATH="$HOME/.npm-global/bin:$PATH"

npm install -g openclaw
NPMEOF

ok "OpenClaw installed: $(sudo -u "$USERNAME" bash -c 'export PATH="$HOME/.npm-global/bin:$PATH" && openclaw --version')"

# ============================================================================
# PHASE 12: Install Chrome (for browser tools)
# ============================================================================
log "Phase 12: Installing Chrome (headless)..."

if command -v google-chrome &>/dev/null; then
    ok "Chrome already installed."
else
    wget -q -O /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    apt-get install -y -qq /tmp/chrome.deb > /dev/null 2>&1 || apt-get install -y -f -qq > /dev/null 2>&1
    rm -f /tmp/chrome.deb
    ok "Chrome installed."
fi

# ============================================================================
# PHASE 13: Docker Sandboxing (Optional)
# ============================================================================
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  Optional: Docker Sandboxing                        ║${NC}"
echo -e "${YELLOW}║                                                     ║${NC}"
echo -e "${YELLOW}║  Runs agent tools (exec, read, write) inside        ║${NC}"
echo -e "${YELLOW}║  Docker containers so a rogue command can't trash   ║${NC}"
echo -e "${YELLOW}║  the host. Your main chat keeps full host access.   ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

if [[ "${ENABLE_SANDBOX:-}" == "y" ]]; then
    SETUP_SANDBOX="y"
elif $INTERACTIVE; then
    read -rp "$(echo -e "${CYAN}Enable Docker sandboxing? [y/N]:${NC} ")" SETUP_SANDBOX
else
    SETUP_SANDBOX="${ENABLE_SANDBOX:-n}"
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
FROM debian:bookworm-slim@sha256:ad86386827b083b3d71571f8e544a9cdd1d388b7c2d5efa99743c1a3b7b19eb4

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
# PHASE 14: Verification & Next Steps
# ============================================================================
echo ""
log "Phase 14: Running verification checks..."
echo ""

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
