#!/usr/bin/env bash
# ============================================================================
# OpenClaw Docker Sandbox Setup
# Adds Docker sandboxing to an existing OpenClaw deployment
#
# Run as clawdbot (after deploy.sh + openclaw onboard):
#   bash sandbox-setup.sh [--dry-run]
#
# What it does:
#   1. Installs Docker CE (if not present)
#   2. Adds clawdbot to docker group
#   3. Builds the OpenClaw sandbox image
#   4. Patches OpenClaw config to enable sandboxing
#   5. Restarts the gateway
#   6. Verifies sandbox is working
#
# What sandboxing does:
#   Your main chat session (direct DMs) runs on the host with full access.
#   Sub-agents, group chats, and Discord channels run tools inside Docker
#   containers — isolated filesystem, no network, resource limits.
#
# Who should use this:
#   ✅ Multi-user setups (exec teams, shared bots)
#   ✅ Bots with access to sensitive credentials (email, CRM, banking)
#   ✅ Public-facing or large server deployments
#   ❌ Solo dev workflows needing full filesystem access across all channels
#   ❌ Software development setups with repo access from non-main sessions
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

log()  { echo -e "${CYAN}[sandbox]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

DRY_RUN=false
USERNAME="clawdbot"
CONFIG_FILE="$HOME/.openclaw/openclaw.json"

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)  DRY_RUN=true; shift ;;
        -h|--help)
            echo "Usage: bash sandbox-setup.sh [--dry-run]"
            echo ""
            echo "Sets up Docker sandboxing for OpenClaw."
            echo "Run after deploy.sh + openclaw onboard."
            echo ""
            echo "  --dry-run   Show what would be done without making changes"
            exit 0
            ;;
        *)  err "Unknown option: $1"; exit 1 ;;
    esac
done

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║    OpenClaw Docker Sandbox Setup                        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if $DRY_RUN; then
    warn "DRY RUN — no changes will be made."
    echo ""
fi

# --- Pre-flight ---
if [[ ! -f "$CONFIG_FILE" ]]; then
    err "OpenClaw config not found at $CONFIG_FILE"
    err "Run 'openclaw onboard --install-daemon' first."
    exit 1
fi

# Check if already configured
if jq -e '.agents.defaults.sandbox.mode // empty | select(. != "off")' "$CONFIG_FILE" > /dev/null 2>&1; then
    CURRENT_MODE=$(jq -r '.agents.defaults.sandbox.mode' "$CONFIG_FILE")
    ok "Sandbox already enabled (mode: ${CURRENT_MODE}). Nothing to do."
    echo ""
    echo -e "  To reconfigure: edit $CONFIG_FILE"
    echo -e "  To disable:     set agents.defaults.sandbox.mode to \"off\""
    exit 0
fi

# ============================================================================
# PHASE 1: Install Docker
# ============================================================================
log "Phase 1: Installing Docker..."

if command -v docker &>/dev/null; then
    ok "Docker already installed: $(docker --version)"
else
    if $DRY_RUN; then
        warn "[dry-run] Would install Docker CE"
    else
        sudo apt-get update -qq
        sudo apt-get install -y -qq ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings

        if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg
        fi

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        sudo apt-get update -qq
        sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
        ok "Docker installed: $(docker --version)"
    fi
fi

# ============================================================================
# PHASE 2: Docker group
# ============================================================================
log "Phase 2: Configuring docker group..."

if groups "$USERNAME" 2>/dev/null | grep -q docker; then
    ok "User '$USERNAME' already in docker group."
else
    if $DRY_RUN; then
        warn "[dry-run] Would add $USERNAME to docker group"
    else
        sudo usermod -aG docker "$USERNAME"
        ok "Added '$USERNAME' to docker group."
    fi
fi

# Helper for docker commands (handles group not yet active in session)
docker_cmd() {
    if groups | grep -q docker; then
        docker "$@"
    else
        sg docker -c "docker $(printf '%q ' "$@")"
    fi
}

# ============================================================================
# PHASE 3: Build sandbox image
# ============================================================================
log "Phase 3: Building sandbox image..."

IMAGE_NAME="openclaw-sandbox:bookworm-slim"

if docker_cmd images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${IMAGE_NAME}$"; then
    ok "Sandbox image already exists: ${IMAGE_NAME}"
else
    if $DRY_RUN; then
        warn "[dry-run] Would build ${IMAGE_NAME}"
    else
        BUILDDIR=$(mktemp -d)
        cat > "$BUILDDIR/Dockerfile" << 'DOCKERFILE'
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
        docker_cmd build -t "$IMAGE_NAME" -f "$BUILDDIR/Dockerfile" "$BUILDDIR"
        rm -rf "$BUILDDIR"
        ok "Sandbox image built: ${IMAGE_NAME}"
    fi
fi

# ============================================================================
# PHASE 4: Patch OpenClaw config
# ============================================================================
log "Phase 4: Patching OpenClaw config..."

if $DRY_RUN; then
    warn "[dry-run] Would set sandbox mode=non-main, scope=session, access=rw"
else
    TMPFILE=$(mktemp)
    jq '.agents.defaults.sandbox = {
        mode: "non-main",
        scope: "session",
        workspaceAccess: "rw"
    }' "$CONFIG_FILE" > "$TMPFILE"
    mv "$TMPFILE" "$CONFIG_FILE"
    ok "Config patched: mode=non-main, scope=session, access=rw"
fi

# ============================================================================
# PHASE 5: Restart gateway
# ============================================================================
log "Phase 5: Restarting gateway..."

if $DRY_RUN; then
    warn "[dry-run] Would restart gateway"
else
    NEEDS_REBOOT=false

    # Check if current shell has docker group
    if ! groups | grep -q docker; then
        NEEDS_REBOOT=true
    fi

    if systemctl is-active --quiet openclaw 2>/dev/null; then
        sudo systemctl restart openclaw
        sleep 3
        if systemctl is-active --quiet openclaw; then
            ok "Gateway restarted via systemd."
            # systemd picks up new groups automatically
            NEEDS_REBOOT=false
        else
            err "Gateway failed to start! Check: journalctl -u openclaw -n 50"
        fi
    elif command -v openclaw &>/dev/null; then
        openclaw gateway restart 2>/dev/null && sleep 3 && ok "Gateway restarted." || warn "Please restart manually."
    fi

    if $NEEDS_REBOOT; then
        echo ""
        warn "Docker group changes require a reboot to take full effect."
        echo -e "  Run: ${GREEN}sudo reboot${NC}"
        echo ""
    fi
fi

# ============================================================================
# PHASE 6: Verify
# ============================================================================
log "Phase 6: Verifying..."

if ! $DRY_RUN; then
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

    check "Docker: installed"           "command -v docker"
    check "Docker: running"             "systemctl is-active docker"
    check "Docker group: $USERNAME"     "groups $USERNAME | grep -q docker"
    check "Sandbox image: exists"       "docker_cmd images --format '{{.Repository}}:{{.Tag}}' | grep -q '$IMAGE_NAME'"
    check "Config: sandbox enabled"     "jq -e '.agents.defaults.sandbox.mode // empty | select(. != \"off\")' $CONFIG_FILE"

    echo ""
    echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
fi

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Sandbox Setup Complete${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}Main session${NC} (direct chat)  → runs on host (full access)"
echo -e "  ${YELLOW}Other sessions${NC} (groups, etc) → sandboxed in Docker"
echo ""
echo -e "  Commands:"
echo -e "    openclaw sandbox list       — list sandbox containers"
echo -e "    openclaw sandbox explain    — show effective policy"
echo ""
echo -e "  To disable later:"
echo -e "    Set agents.defaults.sandbox.mode to \"off\" in config"
echo ""
echo -e "🦞 ${CYAN}Done.${NC}"
