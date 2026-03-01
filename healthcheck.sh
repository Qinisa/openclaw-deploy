#!/usr/bin/env bash
# ============================================================================
# OpenClaw Health Check Script
# Checks if OpenClaw service is running and restarts if needed.
# Designed to run via systemd timer or cron every 5 minutes.
#
# Usage:
#   bash healthcheck.sh          # Check and restart if needed
#   bash healthcheck.sh --quiet  # Suppress output (for cron)
#
# Author: CrawBot 🦞
# ============================================================================

set -euo pipefail

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

SERVICE="openclaw"
LOG_FILE="/home/clawdbot/.openclaw/logs/healthcheck.log"
MAX_RESTART_ATTEMPTS=3

log() {
    local msg
    msg="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$msg" >> "$LOG_FILE"
    $QUIET || echo "$msg"
}

# Check if service exists
if ! systemctl list-unit-files "$SERVICE.service" &>/dev/null; then
    log "ERROR: $SERVICE service not found"
    exit 1
fi

# Check if running
if systemctl is-active --quiet "$SERVICE"; then
    $QUIET || echo "✓ $SERVICE is running (pid $(systemctl show -p MainPID --value "$SERVICE"))"
    exit 0
fi

log "WARNING: $SERVICE is not running"

# Check recent restart attempts to avoid restart loops
RECENT_RESTARTS=0
if [[ -f "$LOG_FILE" ]]; then
    RECENT_RESTARTS=$(grep -c "Attempting restart" "$LOG_FILE" 2>/dev/null || echo 0)
fi

if [[ $RECENT_RESTARTS -ge $MAX_RESTART_ATTEMPTS ]]; then
    log "ERROR: Too many recent restart attempts ($RECENT_RESTARTS). Manual intervention needed."
    exit 2
fi

log "Attempting restart (#$((RECENT_RESTARTS + 1))/$MAX_RESTART_ATTEMPTS)..."

if sudo systemctl restart "$SERVICE" 2>/dev/null; then
    sleep 3
    if systemctl is-active --quiet "$SERVICE"; then
        log "OK: $SERVICE restarted successfully"
        exit 0
    else
        log "ERROR: $SERVICE failed to start after restart"
        log "Last journal entries:"
        journalctl -u "$SERVICE" -n 10 --no-pager >> "$LOG_FILE" 2>&1
        exit 1
    fi
else
    log "ERROR: Failed to restart $SERVICE"
    exit 1
fi
