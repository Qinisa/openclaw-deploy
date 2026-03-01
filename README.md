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

All scripts can be run as one-liners via curl:

```bash
# Full update (system + OpenClaw + verify)
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/update.sh | bash

# Just OpenClaw
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/update.sh | bash -s -- --openclaw-only

# Just system packages
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/update.sh | bash -s -- --system-only

# Just verification checks
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/update.sh | bash -s -- --verify-only

# Combine flags
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/update.sh | bash -s -- --openclaw-only --verify-only
```

Or clone the repo and run locally:

```bash
git clone https://github.com/Qinisa/openclaw-deploy.git
cd openclaw-deploy
bash update.sh
```

## Health Checks

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/healthcheck.sh | bash

# Quiet mode (for cron)
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/healthcheck.sh | bash -s -- --quiet

# Cron (every 5 minutes)
*/5 * * * * curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/healthcheck.sh | bash -s -- --quiet
```

Features: auto-restart with cooldown, loop protection (max 3 attempts), logging.

## Backups

Back up `~/.openclaw/` (config, workspace, memory, sessions):

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/backup.sh | bash

# Custom backup location
BACKUP_DIR=/mnt/backups curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/backup.sh | bash

# Quiet mode (for cron)
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/backup.sh | bash -s -- --quiet

# Cron (daily at 3am)
0 3 * * * curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/backup.sh | bash -s -- --quiet
```

Features: 7-day rotation, excludes transient files, size reporting.

## Verification

```bash
# One-liner (run as root or with sudo)
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/verify.sh | sudo bash
```

## Docker Sandboxing (Optional)

```bash
# One-liner
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/sandbox-setup.sh | bash

# Dry run (preview changes)
curl -fsSL https://raw.githubusercontent.com/Qinisa/openclaw-deploy/main/sandbox-setup.sh | bash -s -- --dry-run
```

Sandboxing isolates agent tool execution in Docker containers:

- **Main chat session** → runs on host with full access
- **Sub-agents & group chats** → sandboxed in Docker containers
- Rogue commands can't trash the host filesystem
- No network access from sandbox by default
- Resource limits prevent runaway processes

**Recommended for:** Multi-user setups, exec teams, bots with sensitive credentials.
**Not recommended for:** Solo dev workflows needing full filesystem access across all channels.

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
- [ ] **Auto-update timer** — systemd timer for automatic OpenClaw updates
- [ ] **Configurable username** — currently hardcoded to `clawdbot`
- [ ] **Multi-agent support** — deploy per-exec agents (à la SetupClaw)

## License

MIT
