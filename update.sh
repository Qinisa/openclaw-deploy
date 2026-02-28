#!/usr/bin/env bash
# ============================================================================
# OpenClaw VPS Maintenance Script
# Updates system packages, OpenClaw, and re-verifies hardening
#
# Usage (as clawdbot user):
#   bash update.sh [--openclaw-only] [--system-only] [--verify-only] [--sandbox]
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

# --- Ensure passwordless sudo for clawdbot ---
USERNAME="clawdbot"
SUDOERS_FILE="/etc/sudoers.d/${USERNAME}"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"

if [[ ! -f "$SUDOERS_FILE" ]] || ! grep -q "NOPASSWD:ALL" "$SUDOERS_FILE" 2>/dev/null; then
    log "Configuring passwordless sudo for ${USERNAME}..."
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
    ok "Passwordless sudo configured for '${USERNAME}'."
else
    ok "Passwordless sudo already configured."
fi

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

    # Recommended: re-run the official installer (detects existing installs, upgrades in place)
    log "Updating OpenClaw via official installer..."
    curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard

    NEW=$(openclaw --version 2>/dev/null || echo "unknown")

    if [[ "$CURRENT" != "$NEW" ]]; then
        ok "OpenClaw updated: ${CURRENT} → ${NEW}"
    else
        ok "OpenClaw already at latest version (${CURRENT})."
    fi

    # Run doctor to handle config migrations, health checks, and service entrypoint updates
    log "Running openclaw doctor --fix..."
    openclaw doctor --fix --non-interactive || warn "Doctor reported issues — review output above."

    # Restart gateway
    log "Restarting OpenClaw gateway..."
    openclaw gateway restart 2>/dev/null || sudo systemctl restart openclaw
    sleep 3
    if systemctl is-active --quiet openclaw; then
        ok "Gateway restarted successfully."
    else
        err "Gateway failed to start! Check: journalctl -u openclaw -n 50"
    fi

    # Post-update health check
    log "Running health check..."
    openclaw health || warn "Health check reported issues."
fi

# --- Docker Sandbox Check ---
if [[ "$MODE" == "all" || "$MODE" == "--sandbox" ]]; then
    echo ""

    # Check if sandbox is already configured
    SANDBOX_CONFIGURED=false
    if [[ -f "$CONFIG_FILE" ]] && jq -e '.agents.defaults.sandbox.mode' "$CONFIG_FILE" > /dev/null 2>&1; then
        SANDBOX_MODE=$(jq -r '.agents.defaults.sandbox.mode' "$CONFIG_FILE")
        if [[ "$SANDBOX_MODE" != "off" ]]; then
            SANDBOX_CONFIGURED=true
            ok "Docker sandboxing: enabled (mode: ${SANDBOX_MODE})"
        fi
    fi

    if ! $SANDBOX_CONFIGURED; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  Docker sandboxing is not enabled.                  ║${NC}"
        echo -e "${YELLOW}║                                                     ║${NC}"
        echo -e "${YELLOW}║  Sandboxing runs agent tools (exec, read, write)    ║${NC}"
        echo -e "${YELLOW}║  inside Docker containers, so a rogue command       ║${NC}"
        echo -e "${YELLOW}║  can't trash the host. Your main chat stays on      ║${NC}"
        echo -e "${YELLOW}║  the host with full access.                         ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""

        if [[ "$MODE" == "--sandbox" ]]; then
            # Explicit --sandbox flag: don't ask, just do it
            ENABLE_SANDBOX="y"
        else
            read -rp "$(echo -e "${CYAN}Enable Docker sandboxing? [y/N]:${NC} ")" ENABLE_SANDBOX
        fi

        if [[ "${ENABLE_SANDBOX,,}" == "y" || "${ENABLE_SANDBOX,,}" == "yes" ]]; then
            log "Setting up Docker sandboxing..."

            # --- Install Docker ---
            if command -v docker &>/dev/null; then
                ok "Docker already installed: $(docker --version)"
            else
                log "Installing Docker CE..."
                sudo apt-get update -qq
                sudo apt-get install -y -qq ca-certificates curl gnupg
                sudo install -m 0755 -d /etc/apt/keyrings

                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                sudo chmod a+r /etc/apt/keyrings/docker.gpg

                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

                sudo apt-get update -qq
                sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
                ok "Docker installed: $(docker --version)"
            fi

            # --- Docker group ---
            if groups "$USERNAME" 2>/dev/null | grep -q docker; then
                ok "User '$USERNAME' already in docker group."
            else
                sudo usermod -aG docker "$USERNAME"
                ok "Added '$USERNAME' to docker group."
            fi

            # Helper for docker commands
            docker_cmd() {
                if groups | grep -q docker; then
                    docker "$@"
                else
                    sg docker -c "docker $*"
                fi
            }

            # --- Build sandbox image ---
            IMAGE_NAME="openclaw-sandbox:bookworm-slim"
            if docker_cmd images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}$"; then
                ok "Sandbox image already exists: ${IMAGE_NAME}"
            else
                log "Building sandbox image..."
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
                docker_cmd build -t "$IMAGE_NAME" -f "$TMPDIR/Dockerfile" "$TMPDIR"
                rm -rf "$TMPDIR"
                ok "Sandbox image built: ${IMAGE_NAME}"
            fi

            # --- Patch config ---
            if [[ -f "$CONFIG_FILE" ]]; then
                TMPFILE=$(mktemp)
                jq '.agents.defaults.sandbox = {
                    mode: "non-main",
                    scope: "session",
                    workspaceAccess: "rw"
                }' "$CONFIG_FILE" > "$TMPFILE"
                mv "$TMPFILE" "$CONFIG_FILE"
                ok "Config patched: sandbox mode=non-main, scope=session, access=rw"
            else
                err "Config not found at $CONFIG_FILE — skipping config patch."
            fi

            # --- Restart ---
            log "Restarting gateway to apply sandbox config..."
            if systemctl is-active --quiet openclaw 2>/dev/null; then
                sudo systemctl restart openclaw
                sleep 3
                systemctl is-active --quiet openclaw && ok "Gateway restarted." || err "Gateway failed to start!"
            elif command -v openclaw &>/dev/null; then
                openclaw gateway restart 2>/dev/null && sleep 3 && ok "Gateway restarted." || warn "Please restart manually: openclaw gateway restart"
            fi

            echo ""
            ok "Docker sandboxing enabled!"
            echo -e "  Main chat → host (full access)"
            echo -e "  Sub-agents & groups → sandboxed in Docker"
            echo -e "  Commands: ${CYAN}openclaw sandbox list${NC} / ${CYAN}openclaw sandbox explain${NC}"
        else
            warn "Skipping Docker sandboxing. Run again with --sandbox to enable later."
        fi
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

    # Docker sandbox checks (if installed)
    if command -v docker &>/dev/null; then
        echo ""
        echo -e "  ${CYAN}Docker Sandbox${NC}"
        echo ""
        check "Docker: running"             "systemctl is-active docker"
        check "Docker group: $USERNAME"     "groups $USERNAME | grep -q docker"
        check "Sandbox image: exists"       "docker images --format '{{.Repository}}:{{.Tag}}' | grep -q 'openclaw-sandbox:bookworm-slim'"
        check "Config: sandbox enabled"     "jq -e '.agents.defaults.sandbox.mode // empty | select(. != \"off\")' $CONFIG_FILE"
    fi

    echo ""
    echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
    echo ""

    if [ -f /var/run/reboot-required ]; then
        warn "System reboot required (kernel or library update pending)."
    fi
fi

echo -e "🦞 ${CYAN}Maintenance complete.${NC}"
