# AGENTS.md

Operational notes for working in this repository.

## Repository role

- This repository contains deployment/configuration, administration, backup, monitoring, and recovery tooling.
- Application source usually lives in separate repositories.
- Live deployment trees (for example Clanker under `/opt/stacks/joyful-stack`) may contain assembled build contexts that are not fully tracked here.

## Safety and secrets

- Never commit or ask the user to paste populated `.env` files, passwords, API keys, access tokens, repository passwords, private keys, WireGuard private keys, certificates with private material, or database secrets.
- Before suggesting a diagnostic command that could print credentials or secret-bearing configuration, explicitly warn the user.
- Prefer metadata-only commands such as `ls -l`, `stat`, targeted `grep` for non-secret keys, and redacted output.
- Do not suggest unrestricted `docker compose config`, `env`, `printenv`, `set`, `systemctl show ... Environment`, or `cat /etc/vps-backup/*` unless the output is safely redirected/redacted. These can expose secrets.
- Files under `/etc/vps-backup/` are credential material. Inspect permissions/names, not contents, unless there is a specific need and output will not be shared.
- Treat `/home/*/.ssh`, WireGuard configs, ntfy auth, and application data-protection keys as secret-bearing.
- Do not include secrets in Git commits, logs, examples, or chat output.

## Backup conventions

- Backblaze B2 is currently considered **broken / under investigation** for this environment. Do not treat B2 success-path code or old successful logs as proof that it is a viable free off-site destination. Re-evaluate pricing/limits and actual restore/maintenance behavior before relying on it.
- Linux VPS backup tooling lives under `VPS/Backup/<Host>/`.
- Restic is the preferred backup mechanism.
- Keep repository maintenance (forget/prune/check) distinct from ordinary backup runs when practical.
- Avoid CPU-heavy compression or repository maintenance on small VPSes without warning first.
- Clanker is storage-constrained; avoid creating large temporary copies/tarballs there unless necessary.
- Preserve consistent database handling: use SQLite online backup/snapshot logic rather than blindly copying live SQLite databases.
- Preserve NATS/other stateful-service consistency procedures already present in host backup scripts.
- Do not back up Docker images, build cache, containerd cache, package cache, or other regeneratable build/runtime cache unless there is a specific reason.

## Clanker

- Live main Compose tree: `/opt/stacks/joyful-stack`.
- `/opt/joyful-stack` is a symlink to that live tree.
- Current Clanker backup script: `VPS/Backup/Clanker/backup.sh`.
- Installed entry point is normally `/usr/local/sbin/vps-backup`.
- Clanker currently backs up important configuration/application state with restic and creates consistent SQLite/NATS snapshots.
- Before changing backup coverage, compare current Docker mounts with the paths already staged by the script.

## Change style

- Prefer small, reviewable changes.
- Fetch the current Git blob/file before updating it and avoid overwriting newer edits.
- Do not remove legacy backups or destructive recovery material without explicit user approval.
- For operational changes, verify with non-destructive inspection first, then make one change at a time and verify the result.
