# OpenClaw VPS Deploy

Bootstrap and harden a fresh Hetzner Ubuntu VPS for [OpenClaw](https://github.com/openclaw/openclaw) in one command.

## Quick Start

SSH into your fresh VPS as root and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/deploy.sh -o deploy.sh
SSH_PUBKEY="ssh-ed25519 AAAA... your-email@example.com" bash deploy.sh
```

Or clone and run:

```bash
git clone https://github.com/Qinisa/openclaw-deploy.git
cd openclaw-deploy
SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" bash deploy.sh
```

### Non-interactive mode (pipe-safe)

```bash
SSH_PUBKEY="ssh-ed25519 AAAA..." ENABLE_SANDBOX="y" \
  curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/deploy.sh | bash
```

## What It Does

| Phase | Action |
|-------|--------|
| 1 | Creates `clawdbot` user with scoped sudo & SSH key auth |
| 2 | Hardens SSH (no root login, no passwords, key-only) |
| 3 | Configures UFW firewall (deny all, allow SSH) |
| 4 | Installs fail2ban (3 retries, 1h ban) |
| 5 | Disables unnecessary services (CUPS, etc.) |
| 6 | Applies kernel hardening (SYN flood, ICMP, martians) |
| 7 | System updates + unattended-upgrades |
| 8 | Configures 2GB swap (prevents OOM on 4GB boxes) |
| 9 | Log rotation (journald 500M limit + logrotate) |
| 10 | Installs Node.js 22 LTS |
| 11 | Installs OpenClaw |
| 12 | Installs Chrome (headless, for browser tools) |
| 13 | Docker sandboxing (optional) |
| 14 | Verification checklist |

## After Deploy

Log in as `clawdbot` and run:

```bash
openclaw onboard --install-daemon
```

### Recommended: Systemd Hardening

After onboarding, add security hardening to the OpenClaw systemd unit:

```bash
sudo systemctl edit openclaw
```

Add:

```ini
[Service]
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/clawdbot/.openclaw /home/clawdbot/.npm-global
PrivateTmp=yes
```

Then reload: `sudo systemctl daemon-reload && sudo systemctl restart openclaw`

## Maintenance

```bash
# Full update (system + OpenClaw + sandbox check + verify)
bash update.sh

# Combine flags as needed
bash update.sh --system-only --verify-only
bash update.sh --openclaw-only --verify-only

# Just OpenClaw
bash update.sh --openclaw-only

# Just system packages
bash update.sh --system-only

# Just run verification checks
bash update.sh --verify-only

# Enable Docker sandboxing (non-interactive)
bash update.sh --sandbox
```

## Health Checks

A standalone health check script monitors the OpenClaw service:

```bash
# Manual check
bash healthcheck.sh

# Cron (every 5 minutes, quiet mode)
*/5 * * * * /home/clawdbot/projects/openclaw-deploy/healthcheck.sh --quiet
```

Features: auto-restart with cooldown, loop protection (max 3 attempts), logging.

## Backups

Back up `~/.openclaw/` (config, workspace, memory, sessions):

```bash
# Manual backup
bash backup.sh

# Custom location
BACKUP_DIR=/mnt/backups bash backup.sh

# Cron (daily at 3am, quiet mode)
0 3 * * * /home/clawdbot/projects/openclaw-deploy/backup.sh --quiet
```

Features: 7-day rotation, excludes transient files, size reporting.

### Docker Sandboxing

The update script will detect if Docker sandboxing isn't enabled and offer to set it up. This isolates agent tool execution (exec, read, write) in Docker containers:

- **Main chat session** → runs on host with full access
- **Sub-agents & group chats** → sandboxed in Docker containers
- Rogue commands can't trash the host filesystem
- No network access from sandbox by default
- Resource limits prevent runaway processes
- Docker base image pinned to SHA digest for reproducibility

To enable directly: `bash update.sh --sandbox`

## Security Features

- **Scoped sudo** — least-privilege Cmnd_Alias rules (not NOPASSWD:ALL)
- SSH key-only authentication
- Root login disabled
- UFW firewall (deny-by-default)
- Fail2ban brute-force protection
- Kernel hardening (SYN cookies, ICMP restrictions)
- Automatic security updates
- 2GB swap to prevent OOM kills
- Log rotation (journald + logrotate)
- Systemd security sandboxing (NoNewPrivileges, ProtectSystem)
- Optional Docker sandboxing for agent tool isolation

## Requirements

- Fresh Ubuntu 24.04 LTS VPS (tested on Hetzner Cloud)
- Root access for initial setup
- An SSH public key (ed25519 recommended)

## TODO (nice-to-haves for exec-grade)

- [ ] **Tailscale/VPN option** — avoid exposing SSH to the internet
- [ ] **Auto-update timer** — systemd timer for automatic OpenClaw updates (unattended-upgrades only covers OS packages)
- [ ] **Configurable username** — currently hardcoded to `clawdbot`
- [ ] **Multi-agent support** — deploy per-exec agents (à la SetupClaw)

## License

MIT
