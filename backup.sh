#!/usr/bin/env bash
# ============================================================================
# OpenClaw Backup Script
# Backs up ~/.openclaw/ with 7-day rotation. Cron-friendly.
#
# Usage:
#   bash backup.sh                    # Backup to default location
#   BACKUP_DIR=/mnt/backups bash backup.sh  # Custom backup directory
#
# Cron example (daily at 3am):
#   0 3 * * * /home/clawdbot/projects/openclaw-deploy/backup.sh --quiet
#
# Author: CrawBot 🦞
# ============================================================================

set -euo pipefail

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

OPENCLAW_DIR="$HOME/.openclaw"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/openclaw}"
RETENTION_DAYS=7
DATE=$(date -u '+%Y-%m-%d_%H%M%S')
BACKUP_NAME="openclaw-backup-${DATE}.tar.gz"

log() { $QUIET || echo -e "\033[0;36m[backup]\033[0m $*"; }
ok()  { $QUIET || echo -e "\033[0;32m[✓]\033[0m $*"; }
err() { echo -e "\033[0;31m[✗]\033[0m $*" >&2; }

if [[ ! -d "$OPENCLAW_DIR" ]]; then
    err "OpenClaw directory not found: $OPENCLAW_DIR"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

log "Backing up $OPENCLAW_DIR → $BACKUP_DIR/$BACKUP_NAME"

# Create compressed archive (exclude large/transient files)
tar -czf "$BACKUP_DIR/$BACKUP_NAME" \
    --exclude='*.sock' \
    --exclude='node_modules' \
    --exclude='.cache' \
    --exclude='logs/*.log.[0-9]*' \
    -C "$HOME" .openclaw 2>/dev/null

BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_NAME" | awk '{print $1}')
ok "Backup created: $BACKUP_NAME ($BACKUP_SIZE)"

# Rotate old backups
DELETED=0
if [[ -d "$BACKUP_DIR" ]]; then
    while IFS= read -r old_backup; do
        rm -f "$old_backup"
        ((DELETED++))
    done < <(find "$BACKUP_DIR" -name "openclaw-backup-*.tar.gz" -mtime +"$RETENTION_DAYS" -type f 2>/dev/null)
fi

if [[ $DELETED -gt 0 ]]; then
    ok "Rotated $DELETED old backup(s) (retention: ${RETENTION_DAYS} days)"
fi

TOTAL=$(find "$BACKUP_DIR" -name "openclaw-backup-*.tar.gz" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
ok "Backup complete. $TOTAL backup(s) stored, total: $TOTAL_SIZE"
