# Useful Scripts

A collection of deployment configuration, administration helpers, monitoring
scripts, and small utilities used across JoyfulReaper systems.

This repository is not the source repository for the applications it deploys.
Application source lives in its respective project repositories.

## Repository layout

```text
UsefulScripts/
├── VPS/
│   ├── compose.yml
│   ├── .env.example
│   ├── Backup/
│   │   ├── Clanker/
│   │   └── ScopeCreep/
│   ├── Beszel/
│   ├── Clanker/
│   ├── HappyDaytime/
│   ├── HappyEcho/
│   ├── HappyFinger/
│   ├── HappyGopher/
│   ├── HappyQOTD/
│   ├── MissionControl/
│   ├── RandomSteamGame/
│   └── molasses-watch/
├── bash/
├── kvirc/
├── LLMs/
├── powershell/
└── ssh_config.txt
```

## VPS deployment

`VPS/compose.yml` is the version-controlled Compose model for the main VPS
service stack.

The live deployment tree on Clanker is:

```text
/opt/stacks/joyful-stack
```

The deployed copy of `compose.yml` is kept in sync with the repository version.

Application source and other build contexts are staged into the live deployment
tree before Docker builds occur. As a result, not every Compose build context
is expected to exist inside this repository.

For example, the live deployment may contain directories such as:

```text
HappyDiscard/
HappyGemini/
Random_Github/
WhatShouldIWorkOnToday/
```

even though those application source trees are not tracked here.

This repository therefore contains the deployment model and supporting build
files, while `/opt/stacks/joyful-stack` is the actual assembled build and
deployment workspace.

## Main Compose stack

The main stack currently includes services such as:

- NATS with JetStream
- Mission Control Gateway
- Mission Control Archive
- GitActivity
- Mission Control Dashboard
- HappyQOTD
- HappyDaytime
- HappyEcho
- HappyDiscard
- HappyFinger
- HappyGopher
- HappyGemini
- RandomSteamGame
- RandomGitHub
- WhatShouldIWorkOnToday
- ntfy

Some services use the Compose `backend` network, while protocol servers or
special-purpose services may use host networking or explicit host port
bindings.

Several administrative and internal endpoints bind only to localhost or the
WireGuard interface.

## Configuration

The checked-in environment template is:

```text
VPS/.env.example
```

Supply real values through a deployment-local environment file, the shell
environment, or another secret store. Do not commit populated credentials.

The Compose stack references environment variables for application API keys,
Mission Control credentials, authentication, GitHub integration, deployment
image tags, and other runtime secrets.

Validate the configuration from the assembled deployment tree with:

```bash
docker compose config --quiet
```

Avoid sharing unrestricted `docker compose config` output because interpolated
environment values may contain secrets.

## Deploying

The live deployment directory on Clanker is:

```bash
cd /opt/stacks/joyful-stack
```

Typical commands:

```bash
docker compose config --quiet
docker compose build
docker compose up -d
docker compose ps
```

Individual service logs can be inspected with:

```bash
docker compose logs --tail=100 SERVICE
```

## Backups

Backup tooling is stored under:

```text
VPS/Backup/
```

The directory is organized by the host the scripts run on.

### Clanker

```text
VPS/Backup/Clanker/
├── backup.sh
├── scopecreep-repo-maintenance.sh
└── systemd/
```

Clanker performs a daily restic backup to a repository hosted on ScopeCreep
over WireGuard.

The client uses append-only repository access.

Clanker also performs trusted weekly maintenance for the ScopeCreep repository
stored locally on Clanker.

Maintenance includes:

- stale lock cleanup
- 30-day snapshot retention
- pruning
- repository integrity checking
- ntfy success/failure notifications

### ScopeCreep

```text
VPS/Backup/ScopeCreep/
├── backup.sh
├── clanker-repo-maintenance.sh
└── systemd/
```

ScopeCreep performs a daily restic backup to a repository hosted on Clanker
over WireGuard.

ScopeCreep also performs trusted weekly maintenance for the Clanker repository
stored locally on ScopeCreep.

The two systems therefore provide reciprocal peer backups while repository
maintenance remains under the control of the machine physically storing each
repository.

Backup credentials and repository passwords live outside Git under:

```text
/etc/vps-backup/
```

Do not commit them.

## Molasses monitoring

`VPS/molasses-watch/` contains a small systemd-driven monitor that checks:

- WireGuard reachability to Molasses
- Uptime Kuma availability
- recovery after an outage

It can send state-change notifications through ntfy.

Runtime credentials belong in an external environment file such as:

```text
/etc/molasses-watch.env
```

The checked-in `.env.example` is only a template.

## Other utilities

### Linux

`bash/memory.sh` prints a quick host resource summary including:

- CPU usage
- selected systemd service state
- service memory usage
- Docker container usage
- system memory
- disk usage

### PowerShell

The `powershell/` directory contains Windows administration and diagnostic
helpers, including scripts for:

- IIS/application error searching
- cleaning .NET build artifacts
- monitoring GreenCloud bandwidth
- testing protocol services
- viewing network traffic

### KVirc

`kvirc/ntfy_alert.txt` contains an IRC-to-ntfy notification hook.

Do not commit a real ntfy token into this file.

### SSH

`ssh_config.txt` contains convenient SSH host aliases for systems reachable
through the private network and jump hosts.

It contains topology information and should not contain private keys or
passwords.

## Security notes

- Never commit populated `.env` files.
- Never commit API keys, access tokens, repository passwords, certificates,
  private keys, or database files.
- Keep backup credentials under `/etc/vps-backup/` with restrictive
  permissions.
- Treat WireGuard addressing, SSH aliases, hostnames, and service topology as
  operational information even when they are not secrets.
- Review Compose changes before deploying them.
- Back up persistent state before destructive deployment changes.

## License

This repository is licensed under the [MIT License](LICENSE).
