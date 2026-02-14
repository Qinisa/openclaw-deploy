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

After the script completes, log in as `clawdbot` and run:

```bash
openclaw onboard --install-daemon
```

This configures OpenClaw (API keys, Telegram bot, etc.) and installs it as a system daemon.

## Maintenance

Copy `update.sh` to your VPS and run as the `clawdbot` user:

```bash
# Full update (system + OpenClaw + verify)
bash update.sh

# Just OpenClaw
bash update.sh --openclaw-only

# Just system packages
bash update.sh --system-only

# Just run verification checks
bash update.sh --verify-only
```

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

## License

MIT
