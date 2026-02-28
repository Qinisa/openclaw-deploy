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

## What It Does

| Phase | Action |
|-------|--------|
| 1 | Creates `clawdbot` user with SSH key auth |
| 2 | Hardens SSH (no root login, no passwords, key-only) |
| 3 | Configures UFW firewall (deny all, allow SSH) |
| 4 | Installs fail2ban (3 retries, 1h ban) |
| 5 | Disables unnecessary services (CUPS, etc.) |
| 6 | Applies kernel hardening (SYN flood, ICMP, martians) |
| 7 | System updates + unattended-upgrades |
| 8 | Installs Node.js 22 LTS |
| 9 | Installs OpenClaw |
| 10 | Installs Chrome (headless, for browser tools) |
| 11 | Verification checklist |

## After Deploy

Log in as `clawdbot` and run:

```bash
openclaw onboard --install-daemon
```

## Maintenance

```bash
# Full update (system + OpenClaw + verify)
# Will ask if you want to enable Docker sandboxing if not already set up
bash update.sh

# Just OpenClaw
bash update.sh --openclaw-only

# Just system packages
bash update.sh --system-only

# Just run verification checks
bash update.sh --verify-only

# Enable Docker sandboxing (non-interactive)
bash update.sh --sandbox
```

### Docker Sandboxing

The update script will detect if Docker sandboxing isn't enabled and offer to set it up. This isolates agent tool execution (exec, read, write) in Docker containers:

- **Main chat session** → runs on host with full access
- **Sub-agents & group chats** → sandboxed in Docker containers
- Rogue commands can't trash the host filesystem
- No network access from sandbox by default
- Resource limits prevent runaway processes

To enable directly: `bash update.sh --sandbox`

## Requirements

- Fresh Ubuntu 24.04 LTS VPS (tested on Hetzner Cloud)
- Root access for initial setup
- An SSH public key (ed25519 recommended)

## Security Features

- SSH key-only authentication
- Root login disabled
- UFW firewall (deny-by-default)
- Fail2ban brute-force protection
- Kernel hardening (SYN cookies, ICMP restrictions)
- Automatic security updates
- Systemd security sandboxing (NoNewPrivileges, ProtectSystem)
- Optional Docker sandboxing for agent tool isolation

## License

MIT
