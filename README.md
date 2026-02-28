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
| 11 | Optional: Docker sandboxing |
| 12 | Verification checklist |

## After Deploy

Log in as `clawdbot` and run:

```bash
openclaw onboard --install-daemon
```

## Maintenance

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

## Docker Sandboxing (Optional)

Isolate agent tool execution in Docker containers. Run after deploy + onboarding:

```bash
bash sandbox-setup.sh            # Interactive setup
bash sandbox-setup.sh --dry-run  # Preview changes
```

**Recommended for:**
- Multi-user setups (exec teams, shared bots)
- Bots with access to sensitive credentials (email, CRM, banking)
- Public-facing or large server deployments

**Not recommended for:**
- Solo dev workflows needing full filesystem access across all channels
- Software development setups with repo access from non-main sessions

When enabled:
- **Main chat session** (direct DMs) runs on the host with full access
- **Sub-agents, group chats, Discord channels** run tools inside Docker containers with isolated filesystems, no network, and resource limits

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
